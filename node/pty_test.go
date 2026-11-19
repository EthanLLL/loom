package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// A session on a fake connection: what it pushes lands in c.out.
func testSession(t *testing.T) (*session, chan []byte) {
	t.Helper()
	out := make(chan []byte, 1024)
	s := newSession(&conn{out: out, joinRef: "1"}, &config{Shell: "/bin/sh"}, "test")
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	s.ctx = ctx
	return s, out
}

type pushed struct {
	event   string
	payload map[string]any
}

func next(t *testing.T, out chan []byte) pushed {
	t.Helper()
	select {
	case b := <-out:
		var parts []json.RawMessage
		if err := json.Unmarshal(b, &parts); err != nil {
			t.Fatal(err)
		}
		var p pushed
		json.Unmarshal(parts[3], &p.event)
		json.Unmarshal(parts[4], &p.payload)
		return p
	case <-time.After(10 * time.Second):
		t.Fatal("nothing pushed")
		return pushed{}
	}
}

func input(s *session, id, text string) {
	s.ptyInput(request{ID: id, Data: base64.StdEncoding.EncodeToString([]byte(text))})
}

func TestTerminalRunsTheShellAndReportsItsExit(t *testing.T) {
	s, out := testSession(t)
	s.ptyOpen(request{ID: "t1", Cols: 100, Rows: 30})
	if p := next(t, out); p.event != "pty_opened" {
		t.Fatalf("first push %q, want pty_opened", p.event)
	}

	input(s, "t1", "stty size; echo hi-$((1+1)); exit 3\n")

	var screen strings.Builder
	for {
		p := next(t, out)
		if p.event == "pty_out" {
			b, _ := base64.StdEncoding.DecodeString(p.payload["data"].(string))
			screen.Write(b)
			continue
		}
		if p.event != "pty_exit" {
			t.Fatalf("unexpected %q", p.event)
		}
		if code := p.payload["code"].(float64); code != 3 {
			t.Fatalf("exit code %v, want 3", code)
		}
		break
	}
	for _, want := range []string{"30 100", "hi-2"} {
		if !strings.Contains(screen.String(), want) {
			t.Fatalf("output %q lacks %q", screen.String(), want)
		}
	}
	s.wg.Wait()
	if len(s.terms) != 0 {
		t.Fatal("terminal still registered after exit")
	}
}

func TestCancelHangsUpTheShell(t *testing.T) {
	s, out := testSession(t)
	s.ptyOpen(request{ID: "t2"})
	next(t, out)

	s.handle("cancel", json.RawMessage(`{"id":"t2"}`))
	input(s, "t2", "echo late\n") // must find nothing, not a closed queue

	for {
		if p := next(t, out); p.event == "pty_exit" {
			break
		}
	}
	s.wg.Wait()
}

func TestResizeReachesTheShell(t *testing.T) {
	s, out := testSession(t)
	s.ptyOpen(request{ID: "t3", Cols: 80, Rows: 24})
	next(t, out)
	s.ptyResize(request{ID: "t3", Cols: 132, Rows: 40})
	input(s, "t3", "stty size; exit\n")

	var screen strings.Builder
	for {
		p := next(t, out)
		if p.event == "pty_exit" {
			break
		}
		b, _ := base64.StdEncoding.DecodeString(p.payload["data"].(string))
		screen.Write(b)
	}
	if !strings.Contains(screen.String(), "40 132") {
		t.Fatalf("output %q lacks the new size", screen.String())
	}
	s.wg.Wait()
}
