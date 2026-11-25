package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/coder/websocket"
	"golang.org/x/sys/unix"
)

// The slice of the Phoenix channel protocol (serializer 2.0.0) a device needs:
// one socket, one channel ("node"), heartbeats. Every frame is a JSON array
//
//	[join_ref, ref, topic, event, payload]
//
// Pushes from the device carry no ref — nothing it sends wants a reply.

const (
	topic             = "node"
	heartbeatInterval = 15 * time.Second
	writeTimeout      = 20 * time.Second

	// What may wait to go out. A stream's bytes (a port's, a shell's, a
	// file's) queue only a few chunks deep, and the kernel holds back little
	// it has not sent: on a slow line a deep queue is seconds of a screen
	// already gone stale, and the answers behind it miss their timeouts.
	// The pressure goes back to whoever is writing instead, as it should.
	streamQueue = 4
	notSentLow  = 128 << 10
)

// Answers that open something, sent ahead of any stream's bytes: nothing of
// theirs can be waiting yet, and the far end has a timeout on each. A
// stream's end ("exit", "done", "tcp_closed"…) stays behind its bytes.
var urgent = map[string]bool{"rtc_answer": true, "tcp_opened": true, "pty_opened": true, "written": true}

// errRevoked: loom refused the token. Retrying soon will not change that.
var errRevoked = errors.New("loom refused this device's token (removed, or reinstalled elsewhere)")

type frame struct {
	JoinRef *string
	Ref     *string
	Topic   string
	Event   string
	Payload json.RawMessage
}

func (f *frame) UnmarshalJSON(b []byte) error {
	var parts [5]json.RawMessage
	if err := json.Unmarshal(b, &parts); err != nil {
		return err
	}
	for i, dst := range []**string{&f.JoinRef, &f.Ref} {
		if string(parts[i]) != "null" {
			var s string
			if err := json.Unmarshal(parts[i], &s); err != nil {
				return err
			}
			*dst = &s
		}
	}
	if err := json.Unmarshal(parts[2], &f.Topic); err != nil {
		return err
	}
	if err := json.Unmarshal(parts[3], &f.Event); err != nil {
		return err
	}
	f.Payload = parts[4]
	return nil
}

// conn is one live connection: the socket, joined to "node".
type conn struct {
	ws      *websocket.Conn
	out     chan []byte // in order: streams' bytes and their ends
	first   chan []byte // urgent events
	ref     atomic.Int64
	joinRef string
	name    string
}

// socketURL turns loom's origin into the device socket's address.
func socketURL(origin, token string) (string, error) {
	u, err := url.Parse(strings.TrimRight(origin, "/"))
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "https":
		u.Scheme = "wss"
	case "http":
		u.Scheme = "ws"
	default:
		return "", fmt.Errorf("loom url must be http or https, got %q", origin)
	}
	u.Path += "/node/websocket"
	u.RawQuery = url.Values{"vsn": {"2.0.0"}, "token": {token}}.Encode()
	return u.String(), nil
}

// dial connects and joins, returning once loom has accepted the device.
func dial(ctx context.Context, origin, token string, info map[string]string) (*conn, error) {
	addr, err := socketURL(origin, token)
	if err != nil {
		return nil, err
	}

	dctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()

	ws, resp, err := websocket.Dial(dctx, addr, &websocket.DialOptions{
		HTTPHeader: http.Header{"User-Agent": {"loom-node/" + version}},
		HTTPClient: &http.Client{Transport: transport},
	})
	if err != nil {
		if resp != nil && resp.StatusCode == http.StatusForbidden {
			return nil, errRevoked
		}
		return nil, redact(err, token)
	}
	// Files travel as 256 KiB chunks, base64'd; leave room.
	ws.SetReadLimit(8 << 20)

	c := &conn{ws: ws, out: make(chan []byte, streamQueue), first: make(chan []byte, 16)}
	c.joinRef = c.nextRef()
	if err := c.writeNow(dctx, c.joinRef, c.joinRef, topic, "phx_join", info); err != nil {
		ws.CloseNow()
		return nil, err
	}

	// The reply to the join is the first thing that matters; anything else
	// before it would be a protocol error on loom's side.
	for {
		f, err := c.read(dctx)
		if err != nil {
			ws.CloseNow()
			return nil, err
		}
		if f.Event != "phx_reply" || f.Ref == nil || *f.Ref != c.joinRef {
			continue
		}
		var reply struct {
			Status   string `json:"status"`
			Response struct {
				Name   string `json:"name"`
				Reason string `json:"reason"`
			} `json:"response"`
		}
		if err := json.Unmarshal(f.Payload, &reply); err != nil {
			ws.CloseNow()
			return nil, err
		}
		if reply.Status != "ok" {
			ws.CloseNow()
			return nil, fmt.Errorf("loom refused the join: %s", reply.Response.Reason)
		}
		c.name = reply.Response.Name
		return c, nil
	}
}

// redact keeps the token out of an error that quotes the socket's address, as
// a failed dial does: the daemon logs it, and its log is not a secret store.
func redact(err error, token string) error {
	msg := err.Error()
	for _, t := range []string{token, url.QueryEscape(token)} {
		if t != "" {
			msg = strings.ReplaceAll(msg, t, "<token>")
		}
	}
	if msg == err.Error() {
		return err
	}
	return errors.New(msg)
}

func (c *conn) nextRef() string { return strconv.FormatInt(c.ref.Add(1), 10) }

func encode(joinRef, ref any, topic, event string, payload any) ([]byte, error) {
	return json.Marshal([]any{joinRef, ref, topic, event, payload})
}

func (c *conn) writeNow(ctx context.Context, joinRef, ref any, topic, event string, payload any) error {
	b, err := encode(joinRef, ref, topic, event, payload)
	if err != nil {
		return err
	}
	return c.ws.Write(ctx, websocket.MessageText, b)
}

func (c *conn) read(ctx context.Context) (*frame, error) {
	_, b, err := c.ws.Read(ctx)
	if err != nil {
		return nil, err
	}
	var f frame
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, fmt.Errorf("bad frame from loom: %w", err)
	}
	return &f, nil
}

// push queues an event for the device's channel. It blocks while the socket is
// behind, which is the backpressure a big file read needs; ctx is the
// connection's, so a dropped connection unblocks it.
func (c *conn) push(ctx context.Context, event string, payload any) error {
	b, err := encode(c.joinRef, nil, topic, event, payload)
	if err != nil {
		return err
	}
	q := c.out
	if urgent[event] {
		q = c.first
	}
	select {
	case q <- b:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// transport dials loom as http.DefaultTransport would (proxy settings and
// all), on HTTP/1.1 for the upgrade, with TCP_NOTSENT_LOWAT on the socket:
// the kernel takes more only once what it holds unsent is below notSentLow.
var transport = func() *http.Transport {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.ForceAttemptHTTP2 = false
	t.TLSNextProto = map[string]func(string, *tls.Conn) http.RoundTripper{}
	d := &net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second,
		Control: func(_, _ string, raw syscall.RawConn) error {
			// Best effort: a kernel without it only queues more.
			return raw.Control(func(fd uintptr) {
				_ = unix.SetsockoptInt(int(fd), unix.IPPROTO_TCP, unix.TCP_NOTSENT_LOWAT, notSentLow)
			})
		}}
	t.DialContext = d.DialContext
	return t
}()

// run pumps the connection until it fails: writes from the queues, heartbeats,
// and every frame read handed to onEvent. It returns why the connection ended.
func (c *conn) run(ctx context.Context, onEvent func(event string, payload json.RawMessage)) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer c.ws.CloseNow()

	errs := make(chan error, 2)
	var pending atomic.Value // the heartbeat ref still unanswered, or ""
	pending.Store("")

	go func() {
		ticker := time.NewTicker(heartbeatInterval)
		defer ticker.Stop()
		write := func(b []byte) error {
			wctx, wcancel := context.WithTimeout(ctx, writeTimeout)
			defer wcancel()
			return c.ws.Write(wctx, websocket.MessageText, b)
		}
		for {
			var b []byte
			// Urgent events first, whenever there are any.
			select {
			case b = <-c.first:
			default:
				select {
				case <-ctx.Done():
					return
				case b = <-c.first:
				case b = <-c.out:
				case <-ticker.C:
					// Still waiting on the last one: the far end is gone even if
					// the TCP connection has not noticed yet.
					if pending.Load().(string) != "" {
						errs <- errors.New("loom stopped answering heartbeats")
						return
					}
					ref := c.nextRef()
					pending.Store(ref)
					wctx, wcancel := context.WithTimeout(ctx, writeTimeout)
					err := c.writeNow(wctx, nil, ref, "phoenix", "heartbeat", map[string]any{})
					wcancel()
					if err != nil {
						errs <- err
						return
					}
					continue
				}
			}
			if err := write(b); err != nil {
				errs <- err
				return
			}
		}
	}()

	go func() {
		for {
			f, err := c.read(ctx)
			if err != nil {
				errs <- err
				return
			}
			switch {
			case f.Topic == "phoenix" && f.Event == "phx_reply":
				if f.Ref != nil && *f.Ref == pending.Load().(string) {
					pending.Store("")
				}
			case f.Topic != topic:
			case f.Event == "phx_error" || f.Event == "phx_close":
				// The channel is gone — replaced by a newer connection, or the
				// device was removed. Redialling finds out which.
				errs <- errors.New("loom closed the channel")
				return
			case f.Event == "phx_reply":
			default:
				onEvent(f.Event, f.Payload)
			}
		}
	}()

	select {
	case err := <-errs:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}
