// Integration tests for the UDP relay.
//
// These tests stand up the real relay on a loopback UDP socket and drive
// it with packets built by the bonded package. We rely on the relay's
// `Snapshot()` to observe state — no internal field access.
//
// Packet egress/replies are exercised through an in-memory PacketDevice so
// these tests can run without Linux TUN privileges.

package relay

import (
	"bytes"
	"context"
	"encoding/binary"
	"net"
	"testing"
	"time"

	"art.arcane/dispatch-speed-server/bonded"
)

// newLoopbackRelay spins up a relay bound to an ephemeral loopback port
// so tests can run in parallel without colliding.
func newLoopbackRelay(t *testing.T) (*UDPRelay, *net.UDPConn) {
	t.Helper()
	return newLoopbackRelayWith(t, UDPRelayConfig{})
}

// newLoopbackRelayWith lets a test inject a partially-populated config
// (e.g. wiring an Opener). The default fields below match newLoopbackRelay.
func newLoopbackRelayWith(t *testing.T, base UDPRelayConfig) (*UDPRelay, *net.UDPConn) {
	t.Helper()
	cfg := base
	cfg.ListenAddr = "127.0.0.1:0"
	if cfg.SessionIdleTimeout == 0 {
		cfg.SessionIdleTimeout = 30 * time.Second
	}
	if cfg.GapTimeout == 0 {
		cfg.GapTimeout = 20 * time.Millisecond
	}
	r := NewUDPRelay(cfg)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() {
		cancel()
		r.Stop()
	})
	if err := r.Start(ctx); err != nil {
		t.Fatalf("relay start: %v", err)
	}
	clientAddr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("resolve client addr: %v", err)
	}
	conn, err := net.ListenUDP("udp", clientAddr)
	if err != nil {
		t.Fatalf("client listen: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return r, conn
}

// send fires one bonded frame at the relay's listening address.
func send(t *testing.T, conn *net.UDPConn, to net.Addr, o bonded.EncodeOptions) {
	t.Helper()
	buf, err := bonded.Encode(o)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if _, err := conn.WriteTo(buf, to); err != nil {
		t.Fatalf("write: %v", err)
	}
}

// wait spins on r.Snapshot() until pred returns true or the deadline
// elapses. Loops with a 2 ms sleep so tests don't burn CPU.
func wait(t *testing.T, r *UDPRelay, deadline time.Duration, pred func(RelayStats) bool) RelayStats {
	t.Helper()
	end := time.Now().Add(deadline)
	for time.Now().Before(end) {
		s := r.Snapshot()
		if pred(s) {
			return s
		}
		time.Sleep(2 * time.Millisecond)
	}
	final := r.Snapshot()
	t.Fatalf("timeout waiting for predicate; final stats=%+v", final)
	return final
}

func readFrame(t *testing.T, conn *net.UDPConn, deadline time.Duration) bonded.Frame {
	t.Helper()
	buf := make([]byte, 1500)
	if err := conn.SetReadDeadline(time.Now().Add(deadline)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	n, _, err := conn.ReadFromUDP(buf)
	if err != nil {
		t.Fatalf("read frame: %v", err)
	}
	frame, err := bonded.Decode(buf[:n])
	if err != nil {
		t.Fatalf("decode relay frame: %v", err)
	}
	return frame
}

type fakePacketDevice struct {
	writes chan []byte
	reads  chan []byte
}

func newFakePacketDevice() *fakePacketDevice {
	return &fakePacketDevice{
		writes: make(chan []byte, 16),
		reads:  make(chan []byte, 16),
	}
}

func (d *fakePacketDevice) WritePacket(packet []byte) error {
	copyPacket := append([]byte(nil), packet...)
	d.writes <- copyPacket
	return nil
}

func (d *fakePacketDevice) Packets() <-chan []byte { return d.reads }

func (d *fakePacketDevice) inject(packet []byte) {
	d.reads <- append([]byte(nil), packet...)
}

func TestUDPRelay_DecodesAndDeliversInOrderFrames(t *testing.T) {
	r, conn := newLoopbackRelay(t)
	relayAddr := r.ListenAddr()

	// Three contiguous payloads on a single session.
	for i := 0; i < 3; i++ {
		send(t, conn, relayAddr, bonded.EncodeOptions{
			SessionID: 0xCAFE,
			Seq:       uint64(i),
			LinkID:    1,
			Payload:   []byte{byte(i + 1)},
		})
	}

	s := wait(t, r, 500*time.Millisecond, func(s RelayStats) bool {
		return s.BytesEgress >= 3
	})
	if s.PacketsAccepted < 3 {
		t.Fatalf("expected ≥3 accepted packets, got %d", s.PacketsAccepted)
	}
	if s.Sessions != 1 {
		t.Fatalf("expected 1 session, got %d", s.Sessions)
	}
}

func TestUDPRelay_WritesReassembledPayloadToPacketDevice(t *testing.T) {
	device := newFakePacketDevice()
	r, conn := newLoopbackRelayWith(t, UDPRelayConfig{PacketDevice: device})
	relayAddr := r.ListenAddr()
	packet := []byte{0x45, 0x00, 0x00, 0x28, 0x99}

	send(t, conn, relayAddr, bonded.EncodeOptions{
		SessionID: 0xCAFE,
		Seq:       0,
		LinkID:    7,
		Payload:   packet,
	})

	select {
	case got := <-device.writes:
		if !bytes.Equal(got, packet) {
			t.Fatalf("packet device payload mismatch: got %x want %x", got, packet)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("timeout waiting for packet device write")
	}
}

func TestUDPRelay_FramesPacketDeviceRepliesToLatestClient(t *testing.T) {
	device := newFakePacketDevice()
	r, conn := newLoopbackRelayWith(t, UDPRelayConfig{PacketDevice: device})
	relayAddr := r.ListenAddr()

	send(t, conn, relayAddr, bonded.EncodeOptions{
		SessionID: 0x1234,
		Seq:       0,
		LinkID:    11,
		Payload:   []byte{0x45, 0x00, 0x00, 0x14},
	})
	wait(t, r, 500*time.Millisecond, func(s RelayStats) bool {
		return s.BytesEgress >= 4
	})

	reply := []byte{0x45, 0x00, 0x00, 0x34, 0xAB, 0xCD}
	device.inject(reply)
	frame := readFrame(t, conn, 500*time.Millisecond)
	if frame.SessionID != 0x1234 {
		t.Fatalf("wrong session id: got %#x", frame.SessionID)
	}
	if frame.Seq != 0 {
		t.Fatalf("first downstream seq should be 0, got %d", frame.Seq)
	}
	if frame.LinkID != 11 {
		t.Fatalf("reply should use latest link id 11, got %d", frame.LinkID)
	}
	if !bytes.Equal(frame.Payload, reply) {
		t.Fatalf("reply payload mismatch: got %x want %x", frame.Payload, reply)
	}
	wait(t, r, 500*time.Millisecond, func(s RelayStats) bool {
		return s.PacketsOut >= 1 && s.BytesOut >= uint64(len(reply))
	})
}

func TestUDPRelay_FiresNakOnSustainedGap(t *testing.T) {
	r, conn := newLoopbackRelay(t)
	relayAddr := r.ListenAddr()

	// Send seq=0 and seq=2 only; the gap at seq=1 should trigger a NAK
	// once the GapTimeout (20 ms) elapses.
	send(t, conn, relayAddr, bonded.EncodeOptions{
		SessionID: 0xBEEF,
		Seq:       0,
		LinkID:    1,
		Payload:   []byte{1},
	})
	send(t, conn, relayAddr, bonded.EncodeOptions{
		SessionID: 0xBEEF,
		Seq:       2,
		LinkID:    1,
		Payload:   []byte{3},
	})

	wait(t, r, 500*time.Millisecond, func(s RelayStats) bool {
		return s.Naks >= 1
	})
}

func TestUDPRelay_SendsNakFrameOnSustainedGap(t *testing.T) {
	r, conn := newLoopbackRelay(t)
	relayAddr := r.ListenAddr()

	send(t, conn, relayAddr, bonded.EncodeOptions{
		SessionID: 0xBEEF,
		Seq:       0,
		LinkID:    2,
		Payload:   []byte{1},
	})
	send(t, conn, relayAddr, bonded.EncodeOptions{
		SessionID: 0xBEEF,
		Seq:       2,
		LinkID:    2,
		Payload:   []byte{3},
	})

	frame := readFrame(t, conn, 500*time.Millisecond)
	if !frame.IsNak() {
		t.Fatalf("expected NAK frame, got flags=0x%02x", frame.Flags)
	}
	if frame.SessionID != 0xBEEF {
		t.Fatalf("wrong session id: got %#x", frame.SessionID)
	}
	if frame.LinkID != 2 {
		t.Fatalf("wrong link id: got %d", frame.LinkID)
	}
	if len(frame.Payload) != 16 {
		t.Fatalf("NAK payload should be 16 bytes, got %d", len(frame.Payload))
	}
	start := binary.BigEndian.Uint64(frame.Payload[0:8])
	end := binary.BigEndian.Uint64(frame.Payload[8:16])
	if start != 1 || end != 1 {
		t.Fatalf("wrong NAK range: got %d..%d", start, end)
	}
}

func TestUDPRelay_DropsMalformedFrame(t *testing.T) {
	r, conn := newLoopbackRelay(t)
	relayAddr := r.ListenAddr()

	// Garbage that won't parse — wrong magic.
	if _, err := conn.WriteTo([]byte{0xDE, 0xAD, 0x01, 0x00, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, relayAddr); err != nil {
		t.Fatalf("write: %v", err)
	}
	wait(t, r, 200*time.Millisecond, func(s RelayStats) bool {
		return s.PacketsBad >= 1
	})
	if s := r.Snapshot(); s.PacketsAccepted != 0 {
		t.Fatalf("garbage frame should not be accepted, got %d", s.PacketsAccepted)
	}
}

func TestUDPRelay_SessionStateIsStickyAcrossSourceAddresses(t *testing.T) {
	// Models the link-swap case: same session, different source IPs.
	r, _ := newLoopbackRelay(t)
	relayAddr := r.ListenAddr()

	dial := func() *net.UDPConn {
		c, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		t.Cleanup(func() { _ = c.Close() })
		return c
	}
	c1 := dial()
	c2 := dial()

	send(t, c1, relayAddr, bonded.EncodeOptions{SessionID: 0x77, Seq: 0, LinkID: 1, Payload: []byte{1}})
	send(t, c2, relayAddr, bonded.EncodeOptions{SessionID: 0x77, Seq: 1, LinkID: 2, Payload: []byte{2}})

	s := wait(t, r, 500*time.Millisecond, func(s RelayStats) bool {
		return s.BytesEgress >= 2
	})
	if s.Sessions != 1 {
		t.Fatalf("expected sticky session (1), got %d", s.Sessions)
	}
}

// TestUDPRelay_OpenerUnwrapsAndDecodes proves the Phase 9 wiring: when an
// `Opener` is configured the relay unwraps the wire bytes before
// `bonded.Decode`. We use a trivial reversible XOR transform (the same
// pattern the Dart test uses) so the relay-side parity is checked without
// dragging real Noise crypto into a unit test.
func TestUDPRelay_OpenerUnwrapsAndDecodes(t *testing.T) {
	xorMask := byte(0xAA)
	r, conn := newLoopbackRelayWith(t, UDPRelayConfig{
		Opener: func(b []byte) ([]byte, error) {
			out := make([]byte, len(b))
			for i, v := range b {
				out[i] = v ^ xorMask
			}
			return out, nil
		},
	})
	relayAddr := r.ListenAddr()

	// Encode a normal bonded frame, then XOR it before shipping. The
	// relay's Opener undoes the XOR and the rest of the pipeline decodes
	// it as usual.
	buf, err := bonded.Encode(bonded.EncodeOptions{
		SessionID: 0x9009,
		Seq:       0,
		LinkID:    1,
		Payload:   []byte{0x01, 0x02, 0x03},
	})
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	wire := make([]byte, len(buf))
	for i, v := range buf {
		wire[i] = v ^ xorMask
	}
	if _, err := conn.WriteTo(wire, relayAddr); err != nil {
		t.Fatalf("write: %v", err)
	}

	s := wait(t, r, 500*time.Millisecond, func(s RelayStats) bool {
		return s.PacketsAccepted >= 1
	})
	if s.PacketsSealRejected != 0 {
		t.Fatalf("expected no seal rejections, got %d", s.PacketsSealRejected)
	}
}

// TestUDPRelay_OpenerRejectsCountsTowardSealRejected proves an Opener
// returning an error increments the dedicated counter and drops the
// packet without touching the bonded decoder.
func TestUDPRelay_OpenerRejectsCountsTowardSealRejected(t *testing.T) {
	r, conn := newLoopbackRelayWith(t, UDPRelayConfig{
		Opener: func(b []byte) ([]byte, error) {
			return nil, errOpenerReject
		},
	})
	relayAddr := r.ListenAddr()

	if _, err := conn.WriteTo([]byte{1, 2, 3, 4}, relayAddr); err != nil {
		t.Fatalf("write: %v", err)
	}
	s := wait(t, r, 500*time.Millisecond, func(s RelayStats) bool {
		return s.PacketsSealRejected >= 1
	})
	if s.PacketsBad != 0 {
		t.Fatalf("rejected by opener must NOT count toward PacketsBad, got %d",
			s.PacketsBad)
	}
	if s.PacketsAccepted != 0 {
		t.Fatalf("rejected packet must not be accepted, got %d", s.PacketsAccepted)
	}
}

var errOpenerReject = openerRejectString("intentional reject")

type openerRejectString string

func (e openerRejectString) Error() string { return string(e) }
