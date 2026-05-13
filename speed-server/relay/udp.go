// Package relay hosts the bonded transport's server-side machinery.
//
// `UDPRelay` is the v0 listener: a single goroutine read-loop that decodes
// inbound bonded frames, dispatches them to per-session workers, writes
// reassembled payloads to a packet device, and re-encodes packet-device
// replies back to the client.
//
// Status (Phase 8.6):
//   - Decode + per-session reassembly: implemented.
//   - Packet-device egress: implemented behind an injectable PacketDevice.
//     Production wires this to a Linux TUN; unit tests use an in-memory fake.
//   - Reverse path (server → client bonded frames): implemented for packet
//     replies and NAKs. ACK/control negotiation still belongs to the auth
//     handshake work.
//
// Threading model: one goroutine drains the UDP socket; each session runs
// in its own goroutine and communicates via an unbuffered channel of
// inbound frames. We keep sessions sticky to a goroutine so each
// reassembler stays single-owner (no mutex inside the reassembler).
package relay

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"sync"
	"time"

	"art.arcane/dispatch-speed-server/bonded"
)

// UDPRelayConfig bundles relay tunables. Zero values are mapped to the
// production defaults inside [NewUDPRelay].
type UDPRelayConfig struct {
	// ListenAddr is a `host:port` literal passed to `net.ResolveUDPAddr`.
	// Empty means ":443".
	ListenAddr string

	// MaxReadBuffer bounds per-packet UDP reads. Frames bigger than this
	// are dropped; 1500 covers ethernet MTU comfortably.
	MaxReadBuffer int

	// SessionIdleTimeout reaps quiet sessions to keep the session map from
	// ballooning under DDoS. 5 min matches the Speedify defaults.
	SessionIdleTimeout time.Duration

	// GapTimeout is forwarded to each session's reassembler.
	GapTimeout time.Duration

	// WindowSize forwarded to each session's reassembler.
	WindowSize int

	// Logger receives structured events. nil falls back to slog.Default().
	Logger *slog.Logger

	// Opener, when set, is called before `bonded.Decode` on every inbound
	// UDP datagram. It receives the raw wire bytes and returns the plain
	// bonded frame bytes (the post-AEAD payload). Returning an error
	// drops the packet; a `nil` opener is equivalent to identity.
	//
	// Production sets this to `crypto.MakeUDPOpener(transport, replay)`;
	// the lab tests pass `nil` to exercise the unsealed wire format.
	Opener func([]byte) ([]byte, error)

	// Sealer, when set, is called on every outbound frame before being
	// written to the UDP socket. Mirrors `Opener` on the receive side.
	Sealer func([]byte) ([]byte, error)

	// PacketDevice receives reassembled client packets and produces packets
	// that should be framed back to the client. A Linux TUN implementation
	// owns NAT/routing in production; tests pass an in-memory device.
	PacketDevice PacketDevice
}

// PacketDevice is the relay-side packet boundary. WritePacket accepts a
// fully reassembled client packet. Packets emits reverse-path packets that
// should be framed back to the most recently active session.
type PacketDevice interface {
	WritePacket([]byte) error
	Packets() <-chan []byte
}

// UDPRelay is the server entry point for the bonded UDP transport.
type UDPRelay struct {
	cfg           UDPRelayConfig
	log           *slog.Logger
	conn          *net.UDPConn
	mu            sync.Mutex // guards sessions and reverse-path routing state
	sess          map[uint64]*udpSession
	downSeq       map[uint64]uint64
	latestSession uint64
	cancel        context.CancelFunc

	stats RelayStats
}

// RelayStats is the live counter set the `stats` subcommand exposes.
// Atomicity is enforced by the relay's main loop (single writer) so the
// fields stay plain ints — readers MUST go through Snapshot.
type RelayStats struct {
	PacketsIn           uint64
	PacketsBad          uint64 // failed Decode
	PacketsSealRejected uint64 // Opener returned an error
	PacketsAccepted     uint64
	Sessions            int
	Naks                uint64
	BytesIn             uint64
	BytesEgress         uint64 // post-reassembly application bytes
	PacketsOut          uint64 // packet-device replies framed to clients
	BytesOut            uint64 // reverse-path application bytes
}

// udpSession is the per-(sessionId) state. One goroutine per session
// keeps the reassembler single-owner so we don't need a mutex inside it.
type udpSession struct {
	id       uint64
	addr     *net.UDPAddr
	linkID   uint16
	reasm    *bonded.Reassembler
	inbox    chan inboundFrame
	lastSeen time.Time
	cancel   context.CancelFunc
	bytesIn  uint64
	bytesOut uint64 // application bytes emitted post-reassembly
	naks     uint64
}

type inboundFrame struct {
	frame bonded.Frame
	from  *net.UDPAddr
	rxAt  time.Time
}

// NewUDPRelay constructs a relay with reasonable production defaults.
// Apply zero-config tuning by passing a partially-populated config; the
// constructor fills the rest.
func NewUDPRelay(cfg UDPRelayConfig) *UDPRelay {
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = ":443"
	}
	if cfg.MaxReadBuffer == 0 {
		cfg.MaxReadBuffer = 1500
	}
	if cfg.SessionIdleTimeout == 0 {
		cfg.SessionIdleTimeout = 5 * time.Minute
	}
	if cfg.GapTimeout == 0 {
		cfg.GapTimeout = 100 * time.Millisecond
	}
	if cfg.WindowSize == 0 {
		cfg.WindowSize = 4096
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	return &UDPRelay{
		cfg:     cfg,
		log:     cfg.Logger,
		sess:    make(map[uint64]*udpSession),
		downSeq: make(map[uint64]uint64),
	}
}

// ListenAddr returns the actual socket address (only meaningful after
// Start has succeeded and the OS has picked an ephemeral port if the
// caller passed `:0`).
func (r *UDPRelay) ListenAddr() net.Addr {
	if r.conn == nil {
		return nil
	}
	return r.conn.LocalAddr()
}

// Start binds the listening socket and spins up the read-loop goroutine.
// Returns once the socket is bound; the read-loop runs until Stop is
// called or the supplied context is cancelled.
func (r *UDPRelay) Start(parent context.Context) error {
	addr, err := net.ResolveUDPAddr("udp", r.cfg.ListenAddr)
	if err != nil {
		return fmt.Errorf("resolve %q: %w", r.cfg.ListenAddr, err)
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", r.cfg.ListenAddr, err)
	}
	r.conn = conn
	ctx, cancel := context.WithCancel(parent)
	r.cancel = cancel
	r.log.Info("UDP relay listening",
		slog.String("addr", conn.LocalAddr().String()),
		slog.Duration("idle_timeout", r.cfg.SessionIdleTimeout))
	go r.readLoop(ctx)
	go r.sweepLoop(ctx)
	if r.cfg.PacketDevice != nil {
		go r.packetDeviceLoop(ctx)
	}
	return nil
}

// Stop closes the listening socket and tears down every session worker.
// Safe to call multiple times.
func (r *UDPRelay) Stop() {
	if r.cancel != nil {
		r.cancel()
		r.cancel = nil
	}
	if r.conn != nil {
		_ = r.conn.Close()
	}
	r.mu.Lock()
	for _, s := range r.sess {
		if s.cancel != nil {
			s.cancel()
		}
	}
	r.sess = make(map[uint64]*udpSession)
	r.downSeq = make(map[uint64]uint64)
	r.latestSession = 0
	r.mu.Unlock()
}

// Snapshot returns a copy of the live counters. Cheap; called by the
// `stats` HTTP handler on every scrape.
func (r *UDPRelay) Snapshot() RelayStats {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.stats
	s.Sessions = len(r.sess)
	return s
}

// readLoop pulls UDP packets off the socket and routes them to the right
// session goroutine. Per-packet allocation here is O(MaxReadBuffer); we
// rely on Go's escape analysis to keep the buf on the goroutine stack.
func (r *UDPRelay) readLoop(ctx context.Context) {
	buf := make([]byte, r.cfg.MaxReadBuffer)
	for {
		if ctx.Err() != nil {
			return
		}
		// Use a short read deadline so we can poll the context. Without
		// this the goroutine would block forever on the syscall when
		// nothing arrives.
		_ = r.conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		n, addr, err := r.conn.ReadFromUDP(buf)
		if err != nil {
			var nerr net.Error
			if errors.As(err, &nerr) && nerr.Timeout() {
				continue
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			r.log.Warn("udp read", slog.String("err", err.Error()))
			continue
		}
		r.stats.PacketsIn++
		r.stats.BytesIn += uint64(n)
		// If sealing is configured, unseal the raw datagram before
		// parsing the bonded framing. The opener owns replay-window
		// gating and AEAD verification.
		decoded := buf[:n]
		if r.cfg.Opener != nil {
			plain, oerr := r.cfg.Opener(decoded)
			if oerr != nil {
				r.stats.PacketsSealRejected++
				r.log.Debug("seal rejected",
					slog.String("err", oerr.Error()),
					slog.String("peer", addr.String()))
				continue
			}
			decoded = plain
		}
		frame, err := bonded.Decode(decoded)
		if err != nil {
			r.stats.PacketsBad++
			r.log.Debug("decode failed",
				slog.String("err", err.Error()),
				slog.String("peer", addr.String()))
			continue
		}
		r.stats.PacketsAccepted++
		r.dispatch(ctx, frame, addr)
	}
}

// dispatch routes the decoded frame to the right session worker, lazily
// creating one on first contact.
func (r *UDPRelay) dispatch(parent context.Context, f bonded.Frame, from *net.UDPAddr) {
	r.mu.Lock()
	s, ok := r.sess[f.SessionID]
	if !ok {
		// Bound the inbox to keep one noisy session from OOM'ing the
		// relay. 256 frames at 1208 B = 309 KB worst-case buffer.
		s = &udpSession{
			id:     f.SessionID,
			addr:   cloneUDPAddr(from),
			linkID: f.LinkID,
			inbox:  make(chan inboundFrame, 256),
		}
		cfg := bonded.ReassemblerConfig{
			WindowSize: r.cfg.WindowSize,
			GapTimeout: r.cfg.GapTimeout,
		}
		s.reasm = bonded.NewReassembler(cfg)
		s.reasm.SetOutbound(func(payload []byte) {
			r.handleReassembledPayload(s, payload)
		})
		s.reasm.SetNak(func(rng bonded.NakRange) {
			r.handleNak(s, rng)
		})
		ctx, cancel := context.WithCancel(parent)
		s.cancel = cancel
		r.sess[f.SessionID] = s
		r.log.Info("session opened",
			slog.Uint64("session", s.id),
			slog.String("peer", from.String()))
		go r.sessionLoop(ctx, s)
	} else {
		// Refresh peer addr so the reverse path always replies to the
		// last-seen IP — clients swap source addresses mid-session as
		// their underlying links change.
		s.addr = cloneUDPAddr(from)
		s.linkID = f.LinkID
	}
	r.latestSession = f.SessionID
	r.mu.Unlock()

	select {
	case s.inbox <- inboundFrame{frame: f, from: from, rxAt: time.Now()}:
	default:
		// Inbox full; drop. The reassembler's NAK will recover lost seqs.
		r.log.Warn("session inbox full",
			slog.Uint64("session", s.id),
			slog.Uint64("seq", f.Seq))
	}
}

func (r *UDPRelay) handleReassembledPayload(s *udpSession, payload []byte) {
	packet := append([]byte(nil), payload...)
	r.mu.Lock()
	s.bytesOut += uint64(len(packet))
	r.stats.BytesEgress += uint64(len(packet))
	r.mu.Unlock()

	if r.cfg.PacketDevice == nil {
		r.log.Debug("egress bytes",
			slog.Uint64("session", s.id),
			slog.Int("len", len(packet)))
		return
	}
	if err := r.cfg.PacketDevice.WritePacket(packet); err != nil {
		r.log.Warn("packet device write",
			slog.Uint64("session", s.id),
			slog.String("err", err.Error()))
	}
}

func (r *UDPRelay) handleNak(s *udpSession, rng bonded.NakRange) {
	r.mu.Lock()
	s.naks++
	r.stats.Naks++
	r.mu.Unlock()

	r.log.Debug("nak",
		slog.Uint64("session", s.id),
		slog.Uint64("start", rng.StartSeq),
		slog.Uint64("end", rng.EndSeq))
	r.sendControlToSession(s.id, bonded.FlagNak, encodeNakPayload(rng))
}

func (r *UDPRelay) packetDeviceLoop(ctx context.Context) {
	packets := r.cfg.PacketDevice.Packets()
	for {
		select {
		case <-ctx.Done():
			return
		case packet, ok := <-packets:
			if !ok {
				return
			}
			if len(packet) == 0 {
				continue
			}
			r.sendPacketToLatestSession(packet)
		}
	}
}

func (r *UDPRelay) sendPacketToLatestSession(packet []byte) {
	r.mu.Lock()
	sessionID := r.latestSession
	s := r.sess[sessionID]
	if s == nil {
		r.mu.Unlock()
		r.log.Debug("drop packet device reply without active session",
			slog.Int("len", len(packet)))
		return
	}
	addr := cloneUDPAddr(s.addr)
	linkID := s.linkID
	seq := r.downSeq[sessionID]
	r.downSeq[sessionID] = seq + 1
	r.mu.Unlock()

	if r.writeFrame(addr, bonded.EncodeOptions{
		SessionID: sessionID,
		Seq:       seq,
		LinkID:    linkID,
		Payload:   packet,
	}) {
		r.mu.Lock()
		r.stats.PacketsOut++
		r.stats.BytesOut += uint64(len(packet))
		r.mu.Unlock()
	}
}

func (r *UDPRelay) sendControlToSession(sessionID uint64, flags uint8, payload []byte) {
	r.mu.Lock()
	s := r.sess[sessionID]
	if s == nil {
		r.mu.Unlock()
		return
	}
	addr := cloneUDPAddr(s.addr)
	linkID := s.linkID
	r.mu.Unlock()

	r.writeFrame(addr, bonded.EncodeOptions{
		SessionID: sessionID,
		Seq:       0,
		LinkID:    linkID,
		Flags:     flags,
		Payload:   payload,
	})
}

func (r *UDPRelay) writeFrame(addr *net.UDPAddr, opts bonded.EncodeOptions) bool {
	if r.conn == nil || addr == nil {
		return false
	}
	wire, err := bonded.Encode(opts)
	if err != nil {
		r.log.Warn("bonded encode",
			slog.Uint64("session", opts.SessionID),
			slog.String("err", err.Error()))
		return false
	}
	if r.cfg.Sealer != nil {
		sealed, err := r.cfg.Sealer(wire)
		if err != nil {
			r.log.Warn("seal outbound",
				slog.Uint64("session", opts.SessionID),
				slog.String("err", err.Error()))
			return false
		}
		wire = sealed
	}
	if _, err := r.conn.WriteToUDP(wire, addr); err != nil {
		r.log.Warn("udp write",
			slog.Uint64("session", opts.SessionID),
			slog.String("peer", addr.String()),
			slog.String("err", err.Error()))
		return false
	}
	return true
}

func encodeNakPayload(rng bonded.NakRange) []byte {
	payload := make([]byte, 16)
	binary.BigEndian.PutUint64(payload[0:8], rng.StartSeq)
	binary.BigEndian.PutUint64(payload[8:16], rng.EndSeq)
	return payload
}

func cloneUDPAddr(addr *net.UDPAddr) *net.UDPAddr {
	if addr == nil {
		return nil
	}
	out := *addr
	if addr.IP != nil {
		out.IP = append(net.IP(nil), addr.IP...)
	}
	return &out
}

// sessionLoop is the per-session worker. Owns the reassembler exclusively.
func (r *UDPRelay) sessionLoop(ctx context.Context, s *udpSession) {
	tick := time.NewTicker(20 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case f, ok := <-s.inbox:
			if !ok {
				return
			}
			s.lastSeen = f.rxAt
			s.bytesIn += uint64(len(f.frame.Payload)) + uint64(bonded.HeaderSize)
			if f.frame.IsKeepalive() || f.frame.IsAck() || f.frame.IsNak() {
				// Control frames don't go through the reassembler. Real
				// handling lands in Phase 11.
				continue
			}
			s.reasm.OnPayload(f.frame.Seq, f.frame.Payload)
		case <-tick.C:
			s.reasm.Tick()
		}
	}
}

// sweepLoop drops idle sessions on a slow tick.
func (r *UDPRelay) sweepLoop(ctx context.Context) {
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-tick.C:
			r.reapIdle(now)
		}
	}
}

func (r *UDPRelay) reapIdle(now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for id, s := range r.sess {
		if s.lastSeen.IsZero() {
			continue
		}
		if now.Sub(s.lastSeen) < r.cfg.SessionIdleTimeout {
			continue
		}
		if s.cancel != nil {
			s.cancel()
		}
		delete(r.sess, id)
		r.log.Info("session reaped",
			slog.Uint64("session", id),
			slog.Duration("idle", now.Sub(s.lastSeen)))
	}
}
