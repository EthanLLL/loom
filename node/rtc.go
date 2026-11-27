package main

import (
	"errors"
	"fmt"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
)

// A direct line from the user's browser to this device, when the networks in
// between allow it: WebRTC, which does the hole punching, its offer and answer
// passed through loom. The offer names a port on loopback; each data channel
// the browser opens, labelled "tcp:<port>", is joined to it, as tcp.go does
// over loom.
// When loom has a TURN relay (lib/loom/turn.ex), both sides are given it and
// use it when no direct path is found; when there is none either, the
// browser falls back to tcp.go, and loom is the relay.
//
//	loom → device: rtc_offer {id, sdp, ice_servers, turn_servers, port}
//	device → loom: rtc_answer {id, sdp}, error {id, message}
//
// Non-trickle: the answer goes back with every candidate in it. The peer
// lives until it fails, either side closes it, or the connection to loom
// ends, as everything else does.

const (
	// For the STUN servers to answer (or, given a relay, the relay): until
	// a little after the first does, or the most it is waited. Some never answer from some networks
	// (stun.miwifi.com from a home line), and waiting for all of them, as
	// gathering "complete" does, held the answer up the whole time.
	srflxGrace  = 300 * time.Millisecond
	gatherWait  = 2 * time.Second
	connectWait = 30 * time.Second // for the browser to get through, or give up
	// A data channel keeps everything it is given; reading the port stops
	// while this much is unsent, which is how a slow link holds back VNC.
	dcHigh = 1 << 20
	dcLow  = 256 << 10
)

func (s *session) rtcOffer(r request) {
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		sdp, err := s.answer(r)
		if err != nil {
			s.fail(r.ID, err)
			return
		}
		s.c.push(s.ctx, "rtc_answer", map[string]any{"id": r.ID, "sdp": sdp})
	}()
}

func (s *session) answer(r request) (string, error) {
	// Said now, while loom is still listening, rather than as a channel that
	// closes the moment it opens.
	c, err := dialLocal(r.Port)
	if err != nil {
		return "", err
	}
	c.Close()

	var se webrtc.SettingEngine
	// Told apart from a slow link within seconds, so a dead path is let go
	// (and the browser can fall back) rather than left hanging.
	se.SetICETimeouts(5*time.Second, 15*time.Second, 2*time.Second)
	api := webrtc.NewAPI(webrtc.WithSettingEngine(se))

	var servers []webrtc.ICEServer
	for _, u := range r.IceServers {
		if strings.HasPrefix(u, "stun:") {
			servers = append(servers, webrtc.ICEServer{URLs: []string{u}})
		}
	}
	servers = append(servers, r.TurnServers...)
	pc, err := api.NewPeerConnection(webrtc.Configuration{ICEServers: servers})
	if err != nil {
		return "", err
	}

	s.mu.Lock()
	s.peers[r.ID] = pc
	s.mu.Unlock()
	drop := func() {
		s.mu.Lock()
		delete(s.peers, r.ID)
		s.mu.Unlock()
		pc.Close()
	}

	connected := make(chan struct{})
	var once sync.Once
	pc.OnConnectionStateChange(func(st webrtc.PeerConnectionState) {
		switch st {
		case webrtc.PeerConnectionStateConnected:
			once.Do(func() { close(connected) })
			s.audit("rtc %s connected", r.ID)
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
			s.audit("rtc %s %s", r.ID, st)
			go drop()
		}
	})
	pc.OnDataChannel(func(dc *webrtc.DataChannel) { s.bridge(r.ID, r.Port, dc) })

	if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: r.SDP}); err != nil {
		drop()
		return "", fmt.Errorf("bad offer: %w", err)
	}
	ans, err := pc.CreateAnswer(nil)
	if err != nil {
		drop()
		return "", err
	}
	gathered := webrtc.GatheringCompletePromise(pc)
	reflexive := make(chan struct{})
	var first sync.Once
	want := webrtc.ICECandidateTypeSrflx
	if len(r.TurnServers) > 0 {
		want = webrtc.ICECandidateTypeRelay
	}
	pc.OnICECandidate(func(c *webrtc.ICECandidate) {
		if c != nil && c.Typ == want {
			first.Do(func() { close(reflexive) })
		}
	})
	if err := pc.SetLocalDescription(ans); err != nil {
		drop()
		return "", err
	}
	start := time.Now()
	limit := time.NewTimer(gatherWait)
	defer limit.Stop()
	select {
	case <-gathered:
	case <-reflexive:
		select {
		case <-gathered:
		case <-time.After(srflxGrace):
		case <-limit.C:
		}
	case <-limit.C:
	case <-s.ctx.Done():
		drop()
		return "", s.ctx.Err()
	}
	s.audit("rtc %s offered after %s", r.ID, time.Since(start).Round(time.Millisecond))

	go func() {
		select {
		case <-connected:
		case <-time.After(connectWait):
			s.audit("rtc %s never connected", r.ID)
			drop()
		}
	}()
	return pc.LocalDescription().SDP, nil
}

// bridge joins a data channel to the port the offer named.
func (s *session) bridge(id string, port int, dc *webrtc.DataChannel) {
	if dc.Label() != "tcp:"+strconv.Itoa(port) {
		log.Printf("rtc %s: ignoring a data channel labelled %q", id, dc.Label())
		dc.Close()
		return
	}
	// Dialled now, before the channel opens, so the browser's first bytes
	// have somewhere to go.
	c, err := dialLocal(port)
	if err != nil {
		log.Printf("rtc %s: %v", id, err)
		dc.Close()
		return
	}
	s.audit("rtc %s tcp port=%d", id, port)

	closed := make(chan struct{})
	var once sync.Once
	end := func() { once.Do(func() { close(closed); c.Close(); dc.Close() }) }

	low := make(chan struct{}, 1)
	dc.SetBufferedAmountLowThreshold(dcLow)
	dc.OnBufferedAmountLow(func() {
		select {
		case low <- struct{}{}:
		default:
		}
	})
	dc.OnMessage(func(m webrtc.DataChannelMessage) {
		if _, err := c.Write(m.Data); err != nil {
			end()
		}
	})
	dc.OnClose(end)
	dc.OnOpen(func() {
		go func() {
			defer end()
			buf := make([]byte, outChunk)
			for {
				n, err := c.Read(buf)
				if n > 0 {
					if dc.Send(append([]byte(nil), buf[:n]...)) != nil {
						return
					}
					for dc.BufferedAmount() > dcHigh {
						select {
						case <-low:
						case <-closed:
							return
						case <-s.ctx.Done():
							return
						}
					}
				}
				if err != nil {
					if !errors.Is(err, net.ErrClosed) {
						s.audit("rtc %s tcp port=%d closed", id, port)
					}
					return
				}
			}
		}()
	})
}
