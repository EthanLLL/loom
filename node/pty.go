package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

// A terminal on this device for loom's terminal pane: the login shell on a
// PTY, its bytes relayed both ways. Loom keeps the screen (replay, several
// viewers, who sets the size); the device only runs the shell.
//
//	loom → device: pty_open {id, cols, rows}, pty_in {id, data}, pty_resize {id, cols, rows}, cancel {id}
//	device → loom: pty_opened {id}, pty_out {id, data}, pty_exit {id, code}, error {id, message}
//
// Like a command, a terminal ends with the connection: the shell is hung up.

// Keystrokes waiting for the shell. A paste is a few frames; a shell that
// stops reading altogether loses what is beyond this rather than stall the
// connection every other request shares.
const ptyInputQueue = 256

type term struct {
	f    *os.File
	cmd  *exec.Cmd
	in   chan []byte
	once sync.Once
}

// kill hangs up the shell: SIGHUP to its process group, as closing a terminal
// window does, SIGKILL after the grace for whatever ignored it.
func (t *term) kill() {
	t.once.Do(func() {
		if t.cmd.Process != nil {
			pgid := -t.cmd.Process.Pid
			syscall.Kill(pgid, syscall.SIGHUP)
			time.AfterFunc(killGrace, func() { syscall.Kill(pgid, syscall.SIGKILL) })
		}
		close(t.in)
		t.f.Close()
	})
}

func size(cols, rows int) *pty.Winsize {
	clamp := func(n, fallback int) uint16 {
		if n < 1 || n > 1000 {
			return uint16(fallback)
		}
		return uint16(n)
	}
	return &pty.Winsize{Cols: clamp(cols, 80), Rows: clamp(rows, 24)}
}

func (s *session) ptyOpen(r request) {
	home, err := os.UserHomeDir()
	if err != nil {
		s.fail(r.ID, err)
		return
	}

	cmd := exec.Command(s.cfg.Shell, "-l")
	cmd.Dir = home
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "COLORTERM=truecolor", "LOOM_NODE=1")

	f, err := pty.StartWithSize(cmd, size(r.Cols, r.Rows))
	if err != nil {
		s.fail(r.ID, fmt.Errorf("cannot start a terminal: %w", err))
		return
	}

	t := &term{f: f, cmd: cmd, in: make(chan []byte, ptyInputQueue)}
	s.mu.Lock()
	s.terms[r.ID] = t
	s.mu.Unlock()
	s.audit("pty %s open %s pid=%d", r.ID, s.cfg.Shell, cmd.Process.Pid)
	s.c.push(s.ctx, "pty_opened", map[string]any{"id": r.ID})

	// Keystrokes, in order, off the connection's reader.
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		for data := range t.in {
			if _, err := f.Write(data); err != nil {
				return
			}
		}
	}()

	// The shell gone, whatever it left in the background may hold the PTY
	// open; after a moment the terminal is closed anyway, as a window would be.
	exited := make(chan struct{})
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		cmd.Wait()
		close(exited)
		time.AfterFunc(pipeLinger, func() { f.Close() })
	}()

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		buf := make([]byte, outChunk)
		for {
			n, err := f.Read(buf)
			if n > 0 {
				if s.c.push(s.ctx, "pty_out", map[string]any{
					"id": r.ID, "data": base64.StdEncoding.EncodeToString(buf[:n]),
				}) != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}

		s.mu.Lock()
		delete(s.terms, r.ID)
		s.mu.Unlock()
		t.kill()
		<-exited

		code := cmd.ProcessState.ExitCode()
		if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			code = 128 + int(ws.Signal())
		}
		s.audit("pty %s exit code=%d", r.ID, code)
		s.c.push(s.ctx, "pty_exit", map[string]any{"id": r.ID, "code": code})
	}()
}

func (s *session) ptyInput(r request) {
	data, err := base64.StdEncoding.DecodeString(r.Data)
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.terms[r.ID]
	if t == nil {
		return
	}
	select {
	case t.in <- data:
	default:
		log.Printf("pty %s: the shell is not reading; dropped %d bytes of input", r.ID, len(data))
	}
}

func (s *session) ptyResize(r request) {
	s.mu.Lock()
	t := s.terms[r.ID]
	s.mu.Unlock()
	if t != nil {
		if err := pty.Setsize(t.f, size(r.Cols, r.Rows)); err != nil && !errors.Is(err, os.ErrClosed) {
			log.Printf("pty %s: resize: %v", r.ID, err)
		}
	}
}
