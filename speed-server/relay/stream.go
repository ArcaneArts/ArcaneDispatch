package relay

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"art.arcane/dispatch-speed-server/bonded"
)

// Stream relays wrap a TCP-like connection with length-prefixed bonded
// frames. Used by Phase 11 to provide TCP and TLS-on-443 fallbacks for
// links where UDP is blocked or NAT'd unreliably.
//
// Wire format: per record `[uint32 len][frame bytes]` (big-endian).
// `len` is bounded by `MaxFrameSize` (default 1500 bytes, matching the
// UDP path) — anything larger is treated as a protocol violation.

const (
	// streamLengthPrefixSize is the size of the length prefix that
	// precedes every bonded frame on TCP/TLS transports.
	streamLengthPrefixSize = 4
)

// TCPRelayConfig configures the TCP fallback relay.
type TCPRelayConfig struct {
	ListenAddr         string        // ":4430" if empty
	MaxFrameSize       int           // default 1500
	SessionIdleTimeout time.Duration // default 5 min
	GapTimeout         time.Duration // default 100 ms
	WindowSize         int           // default 4096
	Logger             *slog.Logger
	Opener             func([]byte) ([]byte, error)
	Sealer             func([]byte) ([]byte, error)
}

// TCPRelay accepts bonded frames over plaintext TCP.
type TCPRelay struct {
	cfg    TCPRelayConfig
	log    *slog.Logger
	ln     net.Listener
	mu     sync.Mutex
	sess   map[uint64]*streamSession
	cancel context.CancelFunc
	stats  StreamRelayStats
}

// TLSRelayConfig wraps `TCPRelayConfig` plus the TLS cert/key for HTTPS
// (HTTP/1.1 Upgrade) fallback on port 443.
type TLSRelayConfig struct {
	TCPRelayConfig
	CertPEM []byte
	KeyPEM  []byte
}

// TLSRelay implements the HTTPS fallback. A client sends:
//
//	GET /bonded HTTP/1.1
//	Host: server
//	Connection: Upgrade
//	Upgrade: dispatch-bonded/1
//
// On a successful upgrade we treat the hijacked TCP byte stream exactly
// like the plain TCP relay (length-prefixed bonded frames).
type TLSRelay struct {
	cfg    TLSRelayConfig
	log    *slog.Logger
	srv    *http.Server
	mu     sync.Mutex
	sess   map[uint64]*streamSession
	cancel context.CancelFunc
	stats  StreamRelayStats
}

// StreamRelayStats parallels `RelayStats` for the byte-stream transports.
type StreamRelayStats struct {
	PacketsIn           uint64
	PacketsBad          uint64
	PacketsSealRejected uint64
	PacketsAccepted     uint64
	Sessions            int
	Naks                uint64
	BytesIn             uint64
	BytesEgress         uint64
	Connections         uint64
	UpgradeRejected     uint64
}

// streamSession is the per-(sessionId) state shared by TCP + TLS relays.
type streamSession struct {
	id       uint64
	conn     net.Conn
	reasm    *bonded.Reassembler
	inbox    chan bonded.Frame
	lastSeen atomic.Int64 // unix nanos
	cancel   context.CancelFunc
	bytesIn  uint64
	bytesOut uint64
	naks     uint64
}

func defaultStreamTunables(cfg *TCPRelayConfig) {
	if cfg.MaxFrameSize == 0 {
		cfg.MaxFrameSize = 1500
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
}

// NewTCPRelay creates a TCP fallback relay with production defaults.
func NewTCPRelay(cfg TCPRelayConfig) *TCPRelay {
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = ":4430"
	}
	defaultStreamTunables(&cfg)
	return &TCPRelay{
		cfg:  cfg,
		log:  cfg.Logger,
		sess: make(map[uint64]*streamSession),
	}
}

// ListenAddr returns the bound address (after Start).
func (r *TCPRelay) ListenAddr() net.Addr {
	if r.ln == nil {
		return nil
	}
	return r.ln.Addr()
}

// Start binds the TCP listener and spawns the accept loop.
func (r *TCPRelay) Start(parent context.Context) error {
	ln, err := net.Listen("tcp", r.cfg.ListenAddr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", r.cfg.ListenAddr, err)
	}
	r.ln = ln
	ctx, cancel := context.WithCancel(parent)
	r.cancel = cancel
	r.log.Info("TCP relay listening", slog.String("addr", ln.Addr().String()))
	go r.acceptLoop(ctx)
	go r.sweepLoop(ctx, &r.mu, r.sess)
	return nil
}

// Stop tears the relay down.
func (r *TCPRelay) Stop() {
	if r.cancel != nil {
		r.cancel()
		r.cancel = nil
	}
	if r.ln != nil {
		_ = r.ln.Close()
	}
	r.mu.Lock()
	for _, s := range r.sess {
		if s.cancel != nil {
			s.cancel()
		}
		if s.conn != nil {
			_ = s.conn.Close()
		}
	}
	r.sess = make(map[uint64]*streamSession)
	r.mu.Unlock()
}

// Snapshot returns a copy of the live counters.
func (r *TCPRelay) Snapshot() StreamRelayStats {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.stats
	s.Sessions = len(r.sess)
	return s
}

func (r *TCPRelay) acceptLoop(ctx context.Context) {
	for {
		if ctx.Err() != nil {
			return
		}
		conn, err := r.ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			r.log.Warn("tcp accept", slog.String("err", err.Error()))
			continue
		}
		r.stats.Connections++
		go r.serveConn(ctx, conn)
	}
}

func (r *TCPRelay) serveConn(parent context.Context, conn net.Conn) {
	defer conn.Close()
	br := bufio.NewReaderSize(conn, 64*1024)
	for {
		if parent.Err() != nil {
			return
		}
		_ = conn.SetReadDeadline(time.Now().Add(r.cfg.SessionIdleTimeout))
		frame, raw, err := readStreamFrame(br, r.cfg.MaxFrameSize, r.cfg.Opener)
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
				return
			}
			var oerr *openerError
			if errors.As(err, &oerr) {
				r.stats.PacketsSealRejected++
				r.log.Debug("seal rejected", slog.String("peer", conn.RemoteAddr().String()))
				continue
			}
			r.stats.PacketsBad++
			r.log.Debug("tcp decode", slog.String("err", err.Error()))
			return
		}
		r.stats.PacketsIn++
		r.stats.BytesIn += uint64(len(raw)) + streamLengthPrefixSize
		r.stats.PacketsAccepted++
		r.dispatchStream(parent, frame, conn, &r.mu, r.sess, &r.stats)
	}
}

func (r *TCPRelay) sweepLoop(ctx context.Context, mu *sync.Mutex, sess map[uint64]*streamSession) {
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-tick.C:
			reapStreamIdle(now, r.cfg.SessionIdleTimeout, r.log, mu, sess)
		}
	}
}

// dispatchStream is reused by both TCP and TLS relays so we keep the
// per-session bookkeeping in one place.
func (r *TCPRelay) dispatchStream(
	parent context.Context,
	f bonded.Frame,
	conn net.Conn,
	mu *sync.Mutex,
	sess map[uint64]*streamSession,
	stats *StreamRelayStats,
) {
	mu.Lock()
	s, ok := sess[f.SessionID]
	if !ok {
		s = &streamSession{
			id:    f.SessionID,
			conn:  conn,
			inbox: make(chan bonded.Frame, 256),
		}
		cfg := bonded.ReassemblerConfig{
			WindowSize: r.cfg.WindowSize,
			GapTimeout: r.cfg.GapTimeout,
		}
		s.reasm = bonded.NewReassembler(cfg)
		s.reasm.SetOutbound(func(payload []byte) {
			s.bytesOut += uint64(len(payload))
			stats.BytesEgress += uint64(len(payload))
			r.log.Debug("tcp egress bytes",
				slog.Uint64("session", s.id),
				slog.Int("len", len(payload)))
		})
		s.reasm.SetNak(func(rng bonded.NakRange) {
			s.naks++
			stats.Naks++
			r.log.Debug("tcp nak",
				slog.Uint64("session", s.id),
				slog.Uint64("start", rng.StartSeq),
				slog.Uint64("end", rng.EndSeq))
		})
		ctx, cancel := context.WithCancel(parent)
		s.cancel = cancel
		sess[f.SessionID] = s
		r.log.Info("tcp session opened",
			slog.Uint64("session", s.id),
			slog.String("peer", conn.RemoteAddr().String()))
		go r.sessionLoop(ctx, s)
	}
	s.lastSeen.Store(time.Now().UnixNano())
	mu.Unlock()
	select {
	case s.inbox <- f:
	default:
		r.log.Warn("tcp inbox full", slog.Uint64("session", s.id), slog.Uint64("seq", f.Seq))
	}
}

func (r *TCPRelay) sessionLoop(ctx context.Context, s *streamSession) {
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
			s.bytesIn += uint64(len(f.Payload)) + uint64(bonded.HeaderSize)
			if f.IsKeepalive() || f.IsAck() || f.IsNak() {
				continue
			}
			s.reasm.OnPayload(f.Seq, f.Payload)
		case <-tick.C:
			s.reasm.Tick()
		}
	}
}

// reapStreamIdle is shared by the TCP + TLS sweepers.
func reapStreamIdle(
	now time.Time,
	idleTimeout time.Duration,
	log *slog.Logger,
	mu *sync.Mutex,
	sess map[uint64]*streamSession,
) {
	mu.Lock()
	defer mu.Unlock()
	for id, s := range sess {
		ts := s.lastSeen.Load()
		if ts == 0 {
			continue
		}
		last := time.Unix(0, ts)
		if now.Sub(last) < idleTimeout {
			continue
		}
		if s.cancel != nil {
			s.cancel()
		}
		if s.conn != nil {
			_ = s.conn.Close()
		}
		delete(sess, id)
		log.Info("stream session reaped",
			slog.Uint64("session", id),
			slog.Duration("idle", now.Sub(last)))
	}
}

type openerError struct{ err error }

func (e *openerError) Error() string { return "opener: " + e.err.Error() }

// readStreamFrame reads one `[u32 len][frame]` record from `br` and
// returns the decoded bonded frame plus the post-opener raw bytes.
func readStreamFrame(
	br *bufio.Reader,
	maxLen int,
	opener func([]byte) ([]byte, error),
) (bonded.Frame, []byte, error) {
	var hdr [streamLengthPrefixSize]byte
	if _, err := io.ReadFull(br, hdr[:]); err != nil {
		return bonded.Frame{}, nil, err
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if int(n) <= 0 || int(n) > maxLen {
		return bonded.Frame{}, nil, fmt.Errorf("frame length %d out of range (max %d)", n, maxLen)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(br, buf); err != nil {
		return bonded.Frame{}, nil, err
	}
	decoded := buf
	if opener != nil {
		plain, oerr := opener(buf)
		if oerr != nil {
			return bonded.Frame{}, nil, &openerError{err: oerr}
		}
		decoded = plain
	}
	frame, err := bonded.Decode(decoded)
	if err != nil {
		return bonded.Frame{}, nil, err
	}
	return frame, decoded, nil
}

// WriteStreamFrame is the symmetric writer the client uses for TCP/TLS
// fallback. Exposed for cross-language tests that produce wire bytes
// using the same length prefix the relays expect.
func WriteStreamFrame(w io.Writer, frameBytes []byte) error {
	var hdr [streamLengthPrefixSize]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(frameBytes)))
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	if _, err := w.Write(frameBytes); err != nil {
		return err
	}
	return nil
}

// ----- TLS relay (HTTP/1.1 Upgrade) ----------------------------------

// NewTLSRelay creates a TLS+HTTP-Upgrade relay. Pass a self-signed cert
// during development; production callers provide a real chain.
func NewTLSRelay(cfg TLSRelayConfig) *TLSRelay {
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = ":443"
	}
	defaultStreamTunables(&cfg.TCPRelayConfig)
	return &TLSRelay{
		cfg:  cfg,
		log:  cfg.Logger,
		sess: make(map[uint64]*streamSession),
	}
}

// ListenAddr returns the active TLS bound address.
func (r *TLSRelay) ListenAddr() net.Addr {
	if r.srv == nil || r.srv.Addr == "" {
		return nil
	}
	type addrer interface{ Addr() net.Addr }
	if a, ok := any(r.srv).(addrer); ok {
		return a.Addr()
	}
	return nil
}

// Start binds the TLS listener and serves the upgrade endpoint.
func (r *TLSRelay) Start(parent context.Context) (net.Addr, error) {
	cert, err := tls.X509KeyPair(r.cfg.CertPEM, r.cfg.KeyPEM)
	if err != nil {
		return nil, fmt.Errorf("load cert: %w", err)
	}
	ln, err := tls.Listen("tcp", r.cfg.ListenAddr, &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	})
	if err != nil {
		return nil, fmt.Errorf("listen %s: %w", r.cfg.ListenAddr, err)
	}
	addr := ln.Addr()
	mux := http.NewServeMux()
	mux.HandleFunc("/bonded", r.handleUpgrade)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	r.srv = &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	ctx, cancel := context.WithCancel(parent)
	r.cancel = cancel
	r.log.Info("TLS relay listening", slog.String("addr", addr.String()))
	go func() {
		if err := r.srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			r.log.Warn("tls serve", slog.String("err", err.Error()))
		}
	}()
	go r.sweepLoop(ctx, &r.mu, r.sess)
	return addr, nil
}

// Stop closes the listener and cancels every session.
func (r *TLSRelay) Stop() {
	if r.cancel != nil {
		r.cancel()
		r.cancel = nil
	}
	if r.srv != nil {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = r.srv.Shutdown(shutdownCtx)
	}
	r.mu.Lock()
	for _, s := range r.sess {
		if s.cancel != nil {
			s.cancel()
		}
		if s.conn != nil {
			_ = s.conn.Close()
		}
	}
	r.sess = make(map[uint64]*streamSession)
	r.mu.Unlock()
}

// Snapshot returns the current counters.
func (r *TLSRelay) Snapshot() StreamRelayStats {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := r.stats
	s.Sessions = len(r.sess)
	return s
}

func (r *TLSRelay) handleUpgrade(w http.ResponseWriter, req *http.Request) {
	if !strings.EqualFold(req.Header.Get("Connection"), "Upgrade") ||
		!strings.EqualFold(req.Header.Get("Upgrade"), "dispatch-bonded/1") {
		r.stats.UpgradeRejected++
		http.Error(w, "expected dispatch-bonded/1 upgrade", http.StatusBadRequest)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		r.stats.UpgradeRejected++
		http.Error(w, "no hijacker", http.StatusInternalServerError)
		return
	}
	conn, bw, err := hj.Hijack()
	if err != nil {
		r.stats.UpgradeRejected++
		r.log.Warn("hijack failed", slog.String("err", err.Error()))
		return
	}
	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Connection: Upgrade\r\n" +
		"Upgrade: dispatch-bonded/1\r\n\r\n"
	if _, err := bw.Writer.Write([]byte(resp)); err != nil {
		_ = conn.Close()
		return
	}
	if err := bw.Writer.Flush(); err != nil {
		_ = conn.Close()
		return
	}
	r.stats.Connections++
	go r.serveTLSConn(conn, bw)
}

// serveTLSConn drives the post-upgrade byte stream identical to a TCP
// connection: read length-prefixed bonded frames, dispatch by sessionId.
func (r *TLSRelay) serveTLSConn(conn net.Conn, bw *bufio.ReadWriter) {
	defer conn.Close()
	br := bw.Reader
	parent, cancel := context.WithCancel(context.Background())
	defer cancel()
	for {
		_ = conn.SetReadDeadline(time.Now().Add(r.cfg.SessionIdleTimeout))
		frame, raw, err := readStreamFrame(br, r.cfg.MaxFrameSize, r.cfg.Opener)
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) {
				return
			}
			var oerr *openerError
			if errors.As(err, &oerr) {
				r.stats.PacketsSealRejected++
				r.log.Debug("tls seal rejected", slog.String("peer", conn.RemoteAddr().String()))
				continue
			}
			r.stats.PacketsBad++
			r.log.Debug("tls decode", slog.String("err", err.Error()))
			return
		}
		r.stats.PacketsIn++
		r.stats.BytesIn += uint64(len(raw)) + streamLengthPrefixSize
		r.stats.PacketsAccepted++
		r.dispatchTLSFrame(parent, frame, conn)
	}
}

// dispatchTLSFrame mirrors TCPRelay.dispatchStream but writes through
// the TLS session map.
func (r *TLSRelay) dispatchTLSFrame(parent context.Context, f bonded.Frame, conn net.Conn) {
	r.mu.Lock()
	s, ok := r.sess[f.SessionID]
	if !ok {
		s = &streamSession{
			id:    f.SessionID,
			conn:  conn,
			inbox: make(chan bonded.Frame, 256),
		}
		cfg := bonded.ReassemblerConfig{
			WindowSize: r.cfg.WindowSize,
			GapTimeout: r.cfg.GapTimeout,
		}
		s.reasm = bonded.NewReassembler(cfg)
		stats := &r.stats
		s.reasm.SetOutbound(func(payload []byte) {
			s.bytesOut += uint64(len(payload))
			stats.BytesEgress += uint64(len(payload))
			r.log.Debug("tls egress bytes",
				slog.Uint64("session", s.id),
				slog.Int("len", len(payload)))
		})
		s.reasm.SetNak(func(rng bonded.NakRange) {
			s.naks++
			stats.Naks++
			r.log.Debug("tls nak",
				slog.Uint64("session", s.id),
				slog.Uint64("start", rng.StartSeq),
				slog.Uint64("end", rng.EndSeq))
		})
		ctx, cancel := context.WithCancel(parent)
		s.cancel = cancel
		r.sess[f.SessionID] = s
		r.log.Info("tls session opened",
			slog.Uint64("session", s.id),
			slog.String("peer", conn.RemoteAddr().String()))
		go r.sessionLoopTLS(ctx, s)
	}
	s.lastSeen.Store(time.Now().UnixNano())
	r.mu.Unlock()
	select {
	case s.inbox <- f:
	default:
		r.log.Warn("tls inbox full", slog.Uint64("session", s.id), slog.Uint64("seq", f.Seq))
	}
}

func (r *TLSRelay) sessionLoopTLS(ctx context.Context, s *streamSession) {
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
			s.bytesIn += uint64(len(f.Payload)) + uint64(bonded.HeaderSize)
			if f.IsKeepalive() || f.IsAck() || f.IsNak() {
				continue
			}
			s.reasm.OnPayload(f.Seq, f.Payload)
		case <-tick.C:
			s.reasm.Tick()
		}
	}
}

func (r *TLSRelay) sweepLoop(ctx context.Context, mu *sync.Mutex, sess map[uint64]*streamSession) {
	tick := time.NewTicker(30 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-tick.C:
			reapStreamIdle(now, r.cfg.SessionIdleTimeout, r.log, mu, sess)
		}
	}
}

// hijackBufferedReader exposes the bufio.Reader portion of an
// http.Hijacker result for tests that need to drive the byte stream.
func hijackBufferedReader(bw *bufio.ReadWriter) *bufio.Reader { return bw.Reader }

// Compile-time guarantee that bytes.Buffer remains in the import set so
// future test helpers in this file have a ready dependency to reuse.
var _ = bytes.NewBuffer
