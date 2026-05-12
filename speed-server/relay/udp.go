// Package relay hosts the bonded transport's server-side machinery.
//
// `UDPRelay` is the v0 listener: a single goroutine read-loop that decodes
// inbound bonded frames, dispatches them to per-session workers, and
// (eventually) re-encodes outbound traffic back to the client.
//
// Status (Phase 8.6):
//   * Decode + per-session reassembly: implemented.
//   * NAT44 egress: stubbed (the relay logs the would-be public bytes,
//     so we can verify the on-the-wire protocol end-to-end against the
//     Dart client without needing raw-socket privileges or a public IP).
//     Real egress lands in Phase 11 alongside the auto protocol switch.
//   * Reverse path (server → client bonded frames): stub. The handshake +
//     ACK/NAK machinery on the server side is also Phase 11 work.
//
// Threading model: one goroutine drains the UDP socket; each session runs
// in its own goroutine and communicates via an unbuffered channel of
// inbound frames. We keep sessions sticky to a goroutine so each
// reassembler stays single-owner (no mutex inside the reassembler).
package relay

import (
	"context"
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
	// Phase 9 v0 has no outbound traffic from the relay, so this is
	// reserved for Phase 11 when the reverse path goes live.
	Sealer func([]byte) ([]byte, error)
}

// UDPRelay is the server entry point for the bonded UDP transport.
type UDPRelay struct {
	cfg    UDPRelayConfig
	log    *slog.Logger
	conn   *net.UDPConn
	mu     sync.Mutex // guards sessions
	sess   map[uint64]*udpSession
	cancel context.CancelFunc

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
}

// udpSession is the per-(sessionId) state. One goroutine per session
// keeps the reassembler single-owner so we don't need a mutex inside it.
type udpSession struct {
	id         uint64
	addr       *net.UDPAddr
	reasm      *bonded.Reassembler
	inbox      chan inboundFrame
	lastSeen   time.Time
	cancel     context.CancelFunc
	bytesIn    uint64
	bytesOut   uint64 // application bytes emitted post-reassembly
	naks       uint64
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
		cfg:  cfg,
		log:  cfg.Logger,
		sess: make(map[uint64]*udpSession),
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
			id:    f.SessionID,
			addr:  from,
			inbox: make(chan inboundFrame, 256),
		}
		cfg := bonded.ReassemblerConfig{
			WindowSize: r.cfg.WindowSize,
			GapTimeout: r.cfg.GapTimeout,
		}
		s.reasm = bonded.NewReassembler(cfg)
		s.reasm.SetOutbound(func(payload []byte) {
			s.bytesOut += uint64(len(payload))
			r.stats.BytesEgress += uint64(len(payload))
			// Phase 8 v0: log-only NAT44. Phase 11 wires the real egress.
			r.log.Debug("egress bytes",
				slog.Uint64("session", s.id),
				slog.Int("len", len(payload)))
		})
		s.reasm.SetNak(func(rng bonded.NakRange) {
			s.naks++
			r.stats.Naks++
			r.log.Debug("nak",
				slog.Uint64("session", s.id),
				slog.Uint64("start", rng.StartSeq),
				slog.Uint64("end", rng.EndSeq))
			// Reverse path TODO (Phase 11): encode rng into a NAK frame
			// and send back to s.addr. For v0 we just count.
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
		s.addr = from
	}
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
