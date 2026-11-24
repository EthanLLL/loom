package main

import (
	"encoding/base64"
	"fmt"
	"log"
	"net"
	"strconv"
	"sync"
	"time"
)

// A TCP connection to a port on this device's loopback, its bytes relayed
// over loom's connection: how the browser reaches the Mac's own screen
// sharing (VNC on 5900) when it cannot reach the device directly (rtc.go).
// Loopback only: the user already has a shell here, so a local port gives
// them nothing new, while another host would make the device a proxy.
//
//	loom → device: tcp_open {id, port}, tcp_in {id, data}, cancel {id}
//	device → loom: tcp_opened {id}, tcp_out {id, data}, tcp_closed {id}, error {id, message}
//
// Like everything else, a tunnel ends with the connection.

// Bytes from the browser waiting for the port. VNC's client side is small —
// keys, pointer moves, update requests — so a full queue means the far end
// has stopped reading, and the stream, which cannot lose bytes, is closed.
const tcpInputQueue = 1024

type tunnel struct {
	c    net.Conn
	in   chan []byte
	once sync.Once
}

func (t *tunnel) close() {
	t.once.Do(func() {
		close(t.in)
		t.c.Close()
	})
}

func dialLocal(port int) (net.Conn, error) {
	if port < 1 || port > 65535 {
		return nil, fmt.Errorf("no such port: %d", port)
	}
	c, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 3*time.Second)
	if err != nil {
		return nil, fmt.Errorf("nothing is listening on port %d here", port)
	}
	return c, nil
}

func (s *session) tcpOpen(r request) {
	c, err := dialLocal(r.Port)
	if err != nil {
		s.fail(r.ID, err)
		return
	}
	t := &tunnel{c: c, in: make(chan []byte, tcpInputQueue)}
	s.mu.Lock()
	s.tunnels[r.ID] = t
	s.mu.Unlock()
	s.audit("tcp %s open port=%d", r.ID, r.Port)
	s.c.push(s.ctx, "tcp_opened", map[string]any{"id": r.ID})

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		for data := range t.in {
			// The reader then sees the connection closed and tidies up.
			if _, err := c.Write(data); err != nil {
				c.Close()
				return
			}
		}
	}()

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		buf := make([]byte, outChunk)
		for {
			n, err := c.Read(buf)
			if n > 0 {
				if s.c.push(s.ctx, "tcp_out", map[string]any{
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
		delete(s.tunnels, r.ID)
		s.mu.Unlock()
		t.close()
		s.audit("tcp %s closed", r.ID)
		s.c.push(s.ctx, "tcp_closed", map[string]any{"id": r.ID})
	}()
}

func (s *session) tcpInput(r request) {
	data, err := base64.StdEncoding.DecodeString(r.Data)
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t := s.tunnels[r.ID]
	if t == nil {
		return
	}
	select {
	case t.in <- data:
	default:
		log.Printf("tcp %s: the port is not reading; closing", r.ID)
		delete(s.tunnels, r.ID)
		t.close()
	}
}
