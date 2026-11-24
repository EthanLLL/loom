package main

import (
	"encoding/base64"
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
)

// A port that echoes what it is sent, upper-cased, so an echo can't be
// mistaken for what went in.
func echoPort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				buf := make([]byte, 4096)
				for {
					n, err := c.Read(buf)
					if n > 0 {
						c.Write([]byte(strings.ToUpper(string(buf[:n]))))
					}
					if err != nil {
						return
					}
				}
			}()
		}
	}()
	return l.Addr().(*net.TCPAddr).Port
}

func TestTunnelRelaysBothWaysAndReportsTheClose(t *testing.T) {
	s, out := testSession(t)
	s.tcpOpen(request{ID: "v1", Port: echoPort(t)})
	if p := next(t, out); p.event != "tcp_opened" {
		t.Fatalf("first push %q, want tcp_opened", p.event)
	}

	s.tcpInput(request{ID: "v1", Data: base64.StdEncoding.EncodeToString([]byte("hello"))})
	p := next(t, out)
	data, _ := base64.StdEncoding.DecodeString(p.payload["data"].(string))
	if p.event != "tcp_out" || string(data) != "HELLO" {
		t.Fatalf("got %q %q, want tcp_out HELLO", p.event, data)
	}

	s.handle("cancel", []byte(`{"id":"v1"}`))
	if p := next(t, out); p.event != "tcp_closed" {
		t.Fatalf("after cancel %q, want tcp_closed", p.event)
	}
}

func TestTunnelToAClosedPortFails(t *testing.T) {
	s, out := testSession(t)
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()

	s.tcpOpen(request{ID: "v2", Port: port})
	if p := next(t, out); p.event != "error" || !strings.Contains(p.payload["message"].(string), "nothing is listening") {
		t.Fatalf("got %q %v, want an error", p.event, p.payload)
	}
}

// The browser's side played by pion: offer, the device's answer, then a data
// channel to the echo port, end to end over the host's own addresses.
func TestDirectLineReachesALoopbackPort(t *testing.T) {
	s, out := testSession(t)
	port := echoPort(t)

	browser, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer browser.Close()
	dc, err := browser.CreateDataChannel("tcp:"+strconv.Itoa(port), nil)
	if err != nil {
		t.Fatal(err)
	}
	got := make(chan string, 1)
	dc.OnOpen(func() { dc.SendText("over the line") })
	dc.OnMessage(func(m webrtc.DataChannelMessage) { got <- string(m.Data) })

	offer, _ := browser.CreateOffer(nil)
	gathered := webrtc.GatheringCompletePromise(browser)
	browser.SetLocalDescription(offer)
	<-gathered

	s.rtcOffer(request{ID: "r1", SDP: browser.LocalDescription().SDP, Port: port})
	p := next(t, out)
	if p.event != "rtc_answer" {
		t.Fatalf("got %q %v, want rtc_answer", p.event, p.payload)
	}
	if err := browser.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeAnswer, SDP: p.payload["sdp"].(string),
	}); err != nil {
		t.Fatal(err)
	}

	select {
	case m := <-got:
		if m != "OVER THE LINE" {
			t.Fatalf("echo %q", m)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("no echo over the data channel")
	}

	// The device lets go of the peer once the browser does.
	browser.Close()
	deadline := time.Now().Add(20 * time.Second)
	for {
		s.mu.Lock()
		n := len(s.peers)
		s.mu.Unlock()
		if n == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the device kept the peer after the browser closed it")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func TestDirectLineToAClosedPortIsRefusedUpFront(t *testing.T) {
	s, out := testSession(t)
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	port := l.Addr().(*net.TCPAddr).Port
	l.Close()

	s.rtcOffer(request{ID: "r2", SDP: "unused", Port: port})
	if p := next(t, out); p.event != "error" || !strings.Contains(p.payload["message"].(string), "nothing is listening") {
		t.Fatalf("got %q %v, want an error", p.event, p.payload)
	}
}
