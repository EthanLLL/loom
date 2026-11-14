package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/rand/v2"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	outputCap   = 10 << 20 // per command; the rest is counted, not sent
	outChunk    = 32 << 10
	fileChunk   = 256 << 10
	killGrace   = 5 * time.Second
	pipeLinger  = 2 * time.Second // after exit, for a background child holding stdout
	maxBackoff  = 30 * time.Second
	revokedWait = 10 * time.Minute
)

// config is what `loom-node install` writes: the looms this device serves,
// each with the token it was given there, and the shell commands run in. One
// device may serve several looms (a family Mac on two people's); each gets its
// own connection, and an install for one leaves the others alone.
type config struct {
	Looms []loom `json:"looms"`
	Shell string `json:"shell"`

	// Before several looms: the one loom, at the top level. Still read.
	URL   string `json:"url,omitempty"`
	Token string `json:"token,omitempty"`
}

type loom struct {
	URL   string `json:"url"`
	Token string `json:"token"`
}

// One place on every system, macOS included, so it is easy to find and explain.
func configPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, ".config", "loom-node", "config.json")
}

// readConfig is the file as it is, or an empty config when there is none.
func readConfig() (*config, error) {
	var c config
	b, err := os.ReadFile(configPath())
	if errors.Is(err, os.ErrNotExist) {
		return &c, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("%s: %w", configPath(), err)
	}
	if c.URL != "" {
		c.Looms = append([]loom{{URL: c.URL, Token: c.Token}}, c.Looms...)
		c.URL, c.Token = "", ""
	}
	return &c, nil
}

func loadConfig() (*config, error) {
	c, err := readConfig()
	if err != nil {
		return nil, err
	}
	if len(c.Looms) == 0 {
		return nil, fmt.Errorf("%s names no loom; install from loom's Devices", configPath())
	}
	for _, l := range c.Looms {
		if l.URL == "" || l.Token == "" {
			return nil, fmt.Errorf("%s has a loom without url or token; reinstall from loom's Devices", configPath())
		}
	}
	if c.Shell == "" {
		c.Shell = os.Getenv("SHELL")
	}
	if c.Shell == "" {
		c.Shell = "/bin/sh"
	}
	return c, nil
}

// find is the loom at url, if the config still names it.
func (c *config) find(url string) (loom, bool) {
	for _, l := range c.Looms {
		if l.URL == url {
			return l, true
		}
	}
	return loom{}, false
}

func runDaemon(args []string) int {
	if len(args) != 0 {
		fmt.Fprintln(os.Stderr, "usage: loom-node daemon")
		return 2
	}
	log.SetFlags(log.LstdFlags)
	log.Printf("loom-node %s starting", version)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Install and uninstall restart the service, so the looms read here are
	// the ones to serve until then.
	var cfg *config
	for ctx.Err() == nil {
		var err error
		if cfg, err = loadConfig(); err == nil {
			break
		}
		log.Printf("cannot start: %v", err)
		sleep(ctx, time.Minute)
	}
	if ctx.Err() != nil {
		return 0
	}

	var wg sync.WaitGroup
	for _, l := range cfg.Looms {
		wg.Add(1)
		go func() {
			defer wg.Done()
			serveLoom(ctx, l.URL)
		}()
	}
	wg.Wait()
	return 0
}

// serveLoom stays connected to one loom until the daemon stops or the config
// no longer names it.
func serveLoom(ctx context.Context, url string) {
	hostname, _ := os.Hostname()
	backoff := time.Second

	for ctx.Err() == nil {
		// Read every time, so a token renewed by a reinstall is used.
		cfg, err := loadConfig()
		if err != nil {
			log.Printf("%s: %v", url, err)
			sleep(ctx, time.Minute)
			continue
		}
		l, ok := cfg.find(url)
		if !ok {
			log.Printf("%s is no longer in %s; not connecting", url, configPath())
			return
		}

		info := map[string]string{
			"os": runtime.GOOS, "arch": runtime.GOARCH,
			"hostname": hostname, "version": version,
		}
		c, err := dial(ctx, l.URL, l.Token, info)
		if errors.Is(err, errRevoked) {
			log.Printf("%s: %v; retrying in %s", url, err, revokedWait)
			sleep(ctx, revokedWait)
			continue
		}
		if err != nil {
			wait := backoff + rand.N(backoff/2+1)
			log.Printf("cannot reach %s: %v; retrying in %s", url, err, wait.Round(time.Second))
			sleep(ctx, wait)
			backoff = min(backoff*2, maxBackoff)
			continue
		}

		log.Printf("connected to %s as %q", url, c.name)
		started := time.Now()
		err = newSession(c, cfg, url).serve(ctx)
		log.Printf("disconnected from %s: %v", url, err)

		// A connection that held for a while was a real one; start over.
		if time.Since(started) > time.Minute {
			backoff = time.Second
		}
		sleep(ctx, backoff)
	}
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-time.After(d):
	case <-ctx.Done():
	}
}

// session is the work done over one connection. When the connection ends,
// everything still running is killed: nobody is left to see its output, and a
// retry from the agent would otherwise run it twice.
type session struct {
	c    *conn
	cfg  *config
	loom string // its url, for the audit log
	ctx  context.Context

	mu     sync.Mutex
	execs  map[string]*job
	writes map[string]*upload
	wg     sync.WaitGroup
}

func newSession(c *conn, cfg *config, url string) *session {
	return &session{c: c, cfg: cfg, loom: url, execs: map[string]*job{}, writes: map[string]*upload{}}
}

func (s *session) serve(parent context.Context) error {
	ctx, cancel := context.WithCancel(parent)
	s.ctx = ctx
	err := s.c.run(ctx, s.handle)
	cancel()

	s.mu.Lock()
	for _, j := range s.execs {
		j.kill("connection lost")
	}
	for id, u := range s.writes {
		u.abort()
		delete(s.writes, id)
	}
	s.mu.Unlock()
	s.wg.Wait()
	return err
}

type request struct {
	ID      string `json:"id"`
	Cmd     string `json:"cmd"`
	Cwd     string `json:"cwd"`
	Timeout int    `json:"timeout"`
	Session string `json:"session"`
	Path    string `json:"path"`
	Data    string `json:"data"`
	Final   bool   `json:"final"`
}

func (s *session) handle(event string, payload json.RawMessage) {
	var r request
	if err := json.Unmarshal(payload, &r); err != nil || r.ID == "" {
		log.Printf("ignoring a malformed %q", event)
		return
	}

	switch event {
	case "exec":
		s.exec(r)
	case "cancel":
		s.mu.Lock()
		if j := s.execs[r.ID]; j != nil {
			j.kill("cancelled")
		}
		if u := s.writes[r.ID]; u != nil {
			u.abort()
			delete(s.writes, r.ID)
		}
		s.mu.Unlock()
	case "read":
		s.wg.Add(1)
		go func() { defer s.wg.Done(); s.read(r) }()
	case "write":
		s.write(r)
	default:
		log.Printf("ignoring unknown event %q", event)
	}
}

func (s *session) fail(id string, err error) {
	s.c.push(s.ctx, "error", map[string]any{"id": id, "message": err.Error()})
}

// ── exec ────────────────────────────────────────────────────────────────

type job struct {
	cmd      *exec.Cmd
	once     sync.Once
	reason   string
	timedOut atomic.Bool
}

// kill takes down the whole process group: `$SHELL -lc` forks, and a command
// may start its own children.
func (j *job) kill(reason string) {
	j.once.Do(func() {
		j.reason = reason
		if j.cmd.Process == nil {
			return
		}
		pgid := -j.cmd.Process.Pid
		syscall.Kill(pgid, syscall.SIGTERM)
		time.AfterFunc(killGrace, func() { syscall.Kill(pgid, syscall.SIGKILL) })
	})
}

// stream sends a command's output as "out" events until the cap, then only
// counts.
type stream struct {
	s     *session
	id    string
	name  string
	mu    *sync.Mutex
	total *int64
}

func (w *stream) Write(p []byte) (int, error) {
	w.mu.Lock()
	room := outputCap - *w.total
	*w.total += int64(len(p))
	w.mu.Unlock()

	send := p
	if room <= 0 {
		return len(p), nil
	}
	if int64(len(send)) > room {
		send = send[:room]
	}
	for len(send) > 0 {
		n := min(len(send), outChunk)
		w.s.c.push(w.s.ctx, "out", map[string]any{
			"id": w.id, "stream": w.name, "data": base64.StdEncoding.EncodeToString(send[:n]),
		})
		send = send[n:]
	}
	return len(p), nil
}

func (s *session) exec(r request) {
	cwd, err := expand(r.Cwd)
	if err != nil {
		s.fail(r.ID, err)
		return
	}
	if cwd == "" {
		cwd, _ = os.UserHomeDir()
	}
	if st, err := os.Stat(cwd); err != nil || !st.IsDir() {
		s.fail(r.ID, fmt.Errorf("no such directory: %s", cwd))
		return
	}

	timeout := time.Duration(r.Timeout) * time.Second
	if timeout <= 0 {
		timeout = 120 * time.Second
	}

	var mu sync.Mutex
	var total int64
	cmd := exec.Command(s.cfg.Shell, "-lc", r.Cmd)
	cmd.Dir = cwd
	cmd.Env = append(os.Environ(), "LOOM_NODE=1")
	cmd.Stdout = &stream{s: s, id: r.ID, name: "stdout", mu: &mu, total: &total}
	cmd.Stderr = &stream{s: s, id: r.ID, name: "stderr", mu: &mu, total: &total}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = pipeLinger

	j := &job{cmd: cmd}
	s.audit("exec %s cwd=%s timeout=%s session=%s: %s", r.ID, cwd, timeout, r.Session, r.Cmd)

	if err := cmd.Start(); err != nil {
		s.fail(r.ID, err)
		return
	}

	s.mu.Lock()
	s.execs[r.ID] = j
	s.mu.Unlock()

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		started := time.Now()
		timer := time.AfterFunc(timeout, func() { j.timedOut.Store(true); j.kill("timed out") })
		err := cmd.Wait()
		timer.Stop()

		s.mu.Lock()
		delete(s.execs, r.ID)
		s.mu.Unlock()

		code := cmd.ProcessState.ExitCode()
		if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			code = 128 + int(ws.Signal())
		}
		timedOut := j.timedOut.Load()
		if timedOut {
			code = 124
		}
		if code < 0 && err != nil && !errors.Is(err, exec.ErrWaitDelay) {
			code = 255
		}

		mu.Lock()
		truncated := total > outputCap
		mu.Unlock()

		s.audit("exit %s code=%d after %s%s", r.ID, code, time.Since(started).Round(time.Millisecond),
			map[bool]string{true: " (" + j.reason + ")", false: ""}[j.reason != ""])
		s.c.push(s.ctx, "exit", map[string]any{
			"id": r.ID, "code": code, "timed_out": timedOut, "truncated": truncated, "bytes": total,
		})
	}()
}

// ── read ────────────────────────────────────────────────────────────────

func (s *session) read(r request) {
	path, err := expand(r.Path)
	if err != nil {
		s.fail(r.ID, err)
		return
	}
	f, err := os.Open(path)
	if err != nil {
		s.fail(r.ID, err)
		return
	}
	defer f.Close()
	if st, err := f.Stat(); err != nil {
		s.fail(r.ID, err)
		return
	} else if st.IsDir() {
		s.fail(r.ID, fmt.Errorf("%s is a directory; use exec with ls", path))
		return
	}
	s.audit("read %s %s", r.ID, path)

	buf := make([]byte, fileChunk)
	var size int64
	for {
		n, err := f.Read(buf)
		if n > 0 {
			size += int64(n)
			if perr := s.c.push(s.ctx, "chunk", map[string]any{
				"id": r.ID, "data": base64.StdEncoding.EncodeToString(buf[:n]),
			}); perr != nil {
				return
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			s.fail(r.ID, err)
			return
		}
	}
	s.c.push(s.ctx, "done", map[string]any{"id": r.ID, "size": size})
}

// ── write ───────────────────────────────────────────────────────────────

// upload is a file being written: into a temporary file beside the target,
// renamed into place on the last chunk, so a reader never sees half of it.
type upload struct {
	path   string
	tmp    *os.File
	size   int64
	failed bool
}

func (u *upload) abort() {
	if u.tmp != nil {
		u.tmp.Close()
		os.Remove(u.tmp.Name())
		u.tmp = nil
	}
}

func (s *session) write(r request) {
	s.mu.Lock()
	defer s.mu.Unlock()

	u := s.writes[r.ID]
	if u == nil {
		u = &upload{}
		s.writes[r.ID] = u
		path, err := expand(r.Path)
		if err == nil {
			err = os.MkdirAll(filepath.Dir(path), 0o755)
		}
		if err == nil {
			if st, serr := os.Stat(path); serr == nil && st.IsDir() {
				err = fmt.Errorf("%s is a directory", path)
			}
		}
		if err == nil {
			u.path = path
			u.tmp, err = os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".loom-*")
		}
		if err != nil {
			u.failed = true
			s.fail(r.ID, err)
		}
	}
	if u.failed {
		if r.Final {
			delete(s.writes, r.ID)
		}
		return
	}

	data, err := base64.StdEncoding.DecodeString(r.Data)
	if err == nil {
		_, err = u.tmp.Write(data)
		u.size += int64(len(data))
	}
	if err == nil && r.Final {
		err = s.finish(u)
		delete(s.writes, r.ID)
		if err == nil {
			s.audit("write %s %s (%d bytes)", r.ID, u.path, u.size)
			s.c.push(s.ctx, "written", map[string]any{"id": r.ID, "size": u.size, "path": u.path})
			return
		}
	}
	if err != nil {
		u.abort()
		u.failed = true
		s.fail(r.ID, err)
	}
}

func (s *session) finish(u *upload) error {
	mode := os.FileMode(0o644)
	if st, err := os.Stat(u.path); err == nil {
		mode = st.Mode().Perm()
	}
	if err := u.tmp.Chmod(mode); err != nil {
		return err
	}
	if err := u.tmp.Sync(); err != nil {
		return err
	}
	if err := u.tmp.Close(); err != nil {
		return err
	}
	name := u.tmp.Name()
	u.tmp = nil
	if err := os.Rename(name, u.path); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}

// ── helpers ─────────────────────────────────────────────────────────────

// expand resolves a leading ~ — paths come from the model, which writes them
// the way a shell would accept them. Relative paths are taken from home, the
// directory commands run in by default.
func expand(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	switch {
	case path == "~":
		return home, nil
	case strings.HasPrefix(path, "~/"):
		return filepath.Join(home, path[2:]), nil
	case filepath.IsAbs(path):
		return path, nil
	default:
		return filepath.Join(home, path), nil
	}
}

// audit keeps a record on the device of everything loom had it do, apart from
// loom's own transcript, each line naming the loom that asked. Rotated at 5 MB,
// one old file kept; one file for all looms.
var auditMu sync.Mutex

func (s *session) audit(format string, args ...any) {
	audit("%s %s", s.loom, fmt.Sprintf(format, args...))
}

func audit(format string, args ...any) {
	auditMu.Lock()
	defer auditMu.Unlock()

	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	dir := filepath.Join(home, ".local", "state", "loom-node")
	os.MkdirAll(dir, 0o700)
	path := filepath.Join(dir, "log")
	if st, err := os.Stat(path); err == nil && st.Size() > 5<<20 {
		os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, args...))
}
