package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"text/tabwriter"
	"time"
)

// The CLI side: an agent on the loom host calls these from its shell. They ask
// loom over HTTP (NodeController), which relays to the device. Everything
// meant for the model is plain text: output on stdout, problems on stderr, and
// an exit code that is the device's own — or one of these:
const (
	exitTimeout = 124 // the command ran past --timeout and was killed
	exitLoom    = 255 // the device is offline, unknown, or dropped mid-request
)

const retryHint = "run `loom-node list` to see whether it is back online, then retry"

// endpoint is how to reach loom from this host: the file loom writes at boot.
type endpoint struct {
	URL string `json:"url"`
	Key string `json:"key"`
}

func loadEndpoint() (*endpoint, error) {
	home := os.Getenv("LOOM_HOME")
	if home == "" {
		h, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		home = filepath.Join(h, ".loom")
	}
	path := filepath.Join(home, "node-cli.json")
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read %s (is loom running on this host?): %w", path, err)
	}
	var e endpoint
	if err := json.Unmarshal(b, &e); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &e, nil
}

func (e *endpoint) do(method, path string, query url.Values, body io.Reader, contentType string) (*http.Response, error) {
	u := e.URL + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	req, err := http.NewRequest(method, u, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("x-loom-key", e.Key)
	if contentType != "" {
		req.Header.Set("content-type", contentType)
	}
	return http.DefaultClient.Do(req)
}

func die(format string, args ...any) int {
	fmt.Fprintf(os.Stderr, "loom-node: "+format+"\n", args...)
	return exitLoom
}

// refused reports a non-200 answer from loom: `{"error": …}`, already worded
// for whoever reads it.
func refused(resp *http.Response) int {
	var body struct {
		Error   string `json:"error"`
		Offline bool   `json:"offline"`
		Lost    bool   `json:"lost"`
	}
	b, _ := io.ReadAll(resp.Body)
	if json.Unmarshal(b, &body) != nil || body.Error == "" {
		body.Error = fmt.Sprintf("loom answered %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}
	if body.Offline || body.Lost {
		return die("%s; %s", body.Error, retryHint)
	}
	return die("%s", body.Error)
}

// ── list ────────────────────────────────────────────────────────────────

func cliList(args []string) int {
	if len(args) != 0 {
		fmt.Fprintln(os.Stderr, "usage: loom-node list")
		return 2
	}
	e, err := loadEndpoint()
	if err != nil {
		return die("%v", err)
	}
	resp, err := e.do("GET", "/api/node/list", nil, nil, "")
	if err != nil {
		return die("%v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return refused(resp)
	}

	var body struct {
		Nodes []struct {
			Name       string  `json:"name"`
			Online     bool    `json:"online"`
			OS         *string `json:"os"`
			Arch       *string `json:"arch"`
			Hostname   *string `json:"hostname"`
			LastSeenAt *string `json:"last_seen_at"`
		} `json:"nodes"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return die("%v", err)
	}
	if len(body.Nodes) == 0 {
		fmt.Println("no devices registered; the user adds them under Devices in loom's sidebar")
		return 0
	}

	tw := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "NAME\tSTATUS\tSYSTEM\tHOSTNAME\tLAST SEEN")
	for _, n := range body.Nodes {
		status := "offline"
		if n.Online {
			status = "online"
		}
		system := "-"
		if n.OS != nil && n.Arch != nil {
			system = *n.OS + "/" + *n.Arch
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\n", n.Name, status, system, deref(n.Hostname), ago(n.LastSeenAt, n.Online))
	}
	tw.Flush()
	return 0
}

func deref(s *string) string {
	if s == nil || *s == "" {
		return "-"
	}
	return *s
}

func ago(at *string, online bool) string {
	if online {
		return "now"
	}
	if at == nil {
		return "never"
	}
	t, err := time.Parse(time.RFC3339, *at)
	if err != nil {
		return *at
	}
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	}
}

// ── exec ────────────────────────────────────────────────────────────────

func cliExec(args []string) int {
	fs := flag.NewFlagSet("exec", flag.ContinueOnError)
	cwd := fs.String("cwd", "", "directory to run in, on the device (default: home)")
	timeout := fs.Int("timeout", 120, "seconds before the command is killed (max 1800)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: loom-node exec <device> [--cwd DIR] [--timeout SECONDS] -- <command>")
	}
	if len(args) < 1 || strings.HasPrefix(args[0], "-") {
		fs.Usage()
		return 2
	}
	node := args[0]
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	command := strings.Join(fs.Args(), " ")
	if strings.TrimSpace(command) == "" {
		fs.Usage()
		return 2
	}

	e, err := loadEndpoint()
	if err != nil {
		return die("%v", err)
	}
	body, _ := json.Marshal(map[string]any{
		"node": node, "cmd": command, "cwd": devicePath(*cwd), "timeout": *timeout,
		"session": os.Getenv("LOOM_SESSION_ID"),
	})
	resp, err := e.do("POST", "/api/node/exec", nil, bytes.NewReader(body), "application/json")
	if err != nil {
		return die("%v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return refused(resp)
	}

	return relay(resp.Body, node, func(ev map[string]any) (int, bool) {
		switch ev["t"] {
		case "out":
			data, _ := base64.StdEncoding.DecodeString(str(ev["data"]))
			if ev["stream"] == "stderr" {
				os.Stderr.Write(data)
			} else {
				os.Stdout.Write(data)
			}
		case "exit":
			code := int(num(ev["code"]))
			if ev["truncated"] == true {
				fmt.Fprintf(os.Stderr, "\n[loom-node: output truncated at 10 MB of %d bytes]\n", int64(num(ev["bytes"])))
			}
			if ev["timed_out"] == true {
				fmt.Fprintf(os.Stderr, "\n[loom-node: killed after %ds; pass a larger --timeout if it needs longer]\n", *timeout)
				return exitTimeout, true
			}
			return code, true
		}
		return 0, false
	})
}

// relay reads loom's NDJSON stream, handing each event to handle until it says
// the request is over. A stream that ends without that is a lost device.
func relay(r io.Reader, node string, handle func(map[string]any) (int, bool)) int {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 16<<20)
	for sc.Scan() {
		var ev map[string]any
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
			return die("bad answer from loom: %v", err)
		}
		switch ev["t"] {
		case "ping":
			continue
		case "error":
			if ev["lost"] == true {
				return die("%s: %s; %s", node, str(ev["message"]), retryHint)
			}
			return die("%s: %s", node, str(ev["message"]))
		}
		if code, done := handle(ev); done {
			return code
		}
	}
	return die("%s: the connection to loom ended mid-request; %s", node, retryHint)
}

// devicePath undoes the one thing this host's shell does to a path meant for
// the device: an unquoted ~ arrives here already expanded to *our* home.
// /home/ubuntu/x is never what was meant on a Mac, so it goes back to ~/x and
// the device expands it to its own.
func devicePath(p string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" || home == "/" {
		return p
	}
	switch {
	case p == home:
		return "~"
	case strings.HasPrefix(p, home+"/"):
		return "~/" + p[len(home)+1:]
	}
	return p
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

func num(v any) float64 {
	n, _ := v.(float64)
	return n
}

// ── read / write ────────────────────────────────────────────────────────

func cliRead(args []string) int {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: loom-node read <device> <path> > local-file")
		return 2
	}
	node, path := args[0], devicePath(args[1])
	e, err := loadEndpoint()
	if err != nil {
		return die("%v", err)
	}
	resp, err := e.do("GET", "/api/node/read", url.Values{"node": {node}, "path": {path}}, nil, "")
	if err != nil {
		return die("%v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return refused(resp)
	}

	out := bufio.NewWriterSize(os.Stdout, 1<<20)
	defer out.Flush()
	return relay(resp.Body, node, func(ev map[string]any) (int, bool) {
		switch ev["t"] {
		case "chunk":
			data, _ := base64.StdEncoding.DecodeString(str(ev["data"]))
			out.Write(data)
		case "done":
			return 0, true
		}
		return 0, false
	})
}

func cliWrite(args []string) int {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: loom-node write <device> <path> < local-file")
		return 2
	}
	node, path := args[0], devicePath(args[1])
	e, err := loadEndpoint()
	if err != nil {
		return die("%v", err)
	}
	resp, err := e.do("POST", "/api/node/write", url.Values{"node": {node}, "path": {path}},
		os.Stdin, "application/octet-stream")
	if err != nil {
		return die("%v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return refused(resp)
	}
	var body struct {
		Size int64  `json:"size"`
		Path string `json:"path"`
	}
	json.NewDecoder(resp.Body).Decode(&body)
	fmt.Printf("wrote %d bytes to %s:%s\n", body.Size, node, body.Path)
	return 0
}
