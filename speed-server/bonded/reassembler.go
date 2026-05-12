// Sliding-window reassembler for the bonded transport (Go port).
//
// Mirror of `lib/bonded/bonded_reassembler.dart` and
// `macos/ArcaneDispatchTunnel/Bonded/BondedReassembler.swift`. See the
// Dart source for the algorithm narrative; this file is a literal Go
// port with the same emit / NAK semantics.
//
// Threading model: each Reassembler instance is intended to be driven from
// a single goroutine (the relay's per-session worker). Concurrent
// OnPayload calls require external locking — we picked single-goroutine
// over an internal mutex because the typical relay creates one per session
// and the hot path runs inside a per-session goroutine anyway.

package bonded

import (
	"time"
)

// NakRange is a closed-on-both-ends range of seqs the receiver hasn't
// seen yet.
type NakRange struct {
	StartSeq uint64
	EndSeq   uint64
}

// Length returns the number of seqs in the range, inclusive.
func (r NakRange) Length() uint64 { return r.EndSeq - r.StartSeq + 1 }

// ReassemblerStats is a read-only snapshot of the reassembler's counters.
type ReassemblerStats struct {
	NextExpectedSeq uint64
	Delivered       int
	DroppedStale    int
	DroppedDup      int
	Naks            int
	BufferedBytes   int
	BufferedCount   int
}

// ReassemblerConfig bundles the tunables. All zero-valued fields fall
// back to the defaults the Dart and Swift sides use.
type ReassemblerConfig struct {
	InitialNextSeq   uint64
	WindowSize       int
	GapTimeout       time.Duration
	MaxBufferedBytes int
	// Now lets tests inject a deterministic clock; nil means time.Now.
	Now func() time.Time
}

// OutboundFn is fired for every in-order payload the reassembler emits.
type OutboundFn func(payload []byte)

// NakFn is fired when a gap stays open past GapTimeout. The relay
// translates these into NAK frames for the original sender.
type NakFn func(r NakRange)

// Reassembler reorders payloads by seq and surfaces gaps as NakRanges.
//
// Single-goroutine ownership: drive from one goroutine, call Tick from
// the same goroutine. The relay's per-session worker satisfies this.
type Reassembler struct {
	nextSeq          uint64
	buffer           map[uint64][]byte
	gapSince         time.Time
	hasOpenGap       bool
	gapDeadline      time.Time
	windowSize       int
	gapTimeout       time.Duration
	maxBufferedBytes int

	delivered    int
	droppedStale int
	droppedDup   int
	naks         int

	onOutbound OutboundFn
	onNak      NakFn
	now        func() time.Time
}

// NewReassembler builds a Reassembler. Callers MUST register OnOutbound /
// OnNak before the first OnPayload call — broadcasts to nil callbacks are
// silently swallowed.
func NewReassembler(cfg ReassemblerConfig) *Reassembler {
	window := cfg.WindowSize
	if window <= 0 {
		window = 4096
	}
	gap := cfg.GapTimeout
	if gap <= 0 {
		gap = 100 * time.Millisecond
	}
	maxBuf := cfg.MaxBufferedBytes
	if maxBuf <= 0 {
		maxBuf = 4 * 1024 * 1024
	}
	clock := cfg.Now
	if clock == nil {
		clock = time.Now
	}
	return &Reassembler{
		nextSeq:          cfg.InitialNextSeq,
		buffer:           make(map[uint64][]byte),
		windowSize:       window,
		gapTimeout:       gap,
		maxBufferedBytes: maxBuf,
		now:              clock,
	}
}

// SetOutbound registers (or replaces) the in-order delivery callback.
func (r *Reassembler) SetOutbound(fn OutboundFn) { r.onOutbound = fn }

// SetNak registers (or replaces) the NAK callback.
func (r *Reassembler) SetNak(fn NakFn) { r.onNak = fn }

// Snapshot returns a copy of the current counters.
func (r *Reassembler) Snapshot() ReassemblerStats {
	bufBytes := 0
	for _, v := range r.buffer {
		bufBytes += len(v)
	}
	return ReassemblerStats{
		NextExpectedSeq: r.nextSeq,
		Delivered:       r.delivered,
		DroppedStale:    r.droppedStale,
		DroppedDup:      r.droppedDup,
		Naks:            r.naks,
		BufferedBytes:   bufBytes,
		BufferedCount:   len(r.buffer),
	}
}

// OnPayload feeds a payload chunk into the reassembler. The caller is
// expected to have already validated the wire frame (so seq + payload
// have well-defined semantics).
func (r *Reassembler) OnPayload(seq uint64, payload []byte) {
	if seq < r.nextSeq {
		r.droppedDup++
		return
	}
	if seq >= r.nextSeq+uint64(r.windowSize) {
		r.droppedStale++
		return
	}
	if seq == r.nextSeq {
		r.emit(seq, payload)
		r.drainBuffer()
		r.updateGapState()
		return
	}
	if _, exists := r.buffer[seq]; exists {
		r.droppedDup++
		return
	}
	if r.bufferedBytes()+len(payload) > r.maxBufferedBytes {
		r.evictHighest()
	}
	r.buffer[seq] = append([]byte(nil), payload...)
	r.updateGapState()
}

// Tick is the relay's poll hook — call it on every loop iteration with
// the current time so gap timeouts fire. We deliberately don't spawn an
// internal goroutine so the reassembler stays free of the runtime's
// timer overhead; the relay already has a per-session ticker.
func (r *Reassembler) Tick() {
	if !r.hasOpenGap {
		return
	}
	if r.now().Before(r.gapDeadline) {
		return
	}
	r.fireGapTimeout()
}

// emit ships one payload and advances nextSeq.
func (r *Reassembler) emit(seq uint64, payload []byte) {
	if r.onOutbound != nil {
		r.onOutbound(payload)
	}
	r.nextSeq = seq + 1
	r.delivered++
}

// drainBuffer walks contiguous seqs and emits as many as possible.
func (r *Reassembler) drainBuffer() {
	for {
		payload, ok := r.buffer[r.nextSeq]
		if !ok {
			return
		}
		delete(r.buffer, r.nextSeq)
		r.emit(r.nextSeq, payload)
	}
}

// updateGapState reconciles the gap-timeout bookkeeping after a change in
// the buffer.
func (r *Reassembler) updateGapState() {
	hasGap := len(r.buffer) > 0
	if !hasGap {
		r.hasOpenGap = false
		return
	}
	if !r.hasOpenGap {
		r.gapSince = r.now()
		r.gapDeadline = r.gapSince.Add(r.gapTimeout)
		r.hasOpenGap = true
	}
}

// fireGapTimeout emits a NAK range covering the first hole and re-arms.
func (r *Reassembler) fireGapTimeout() {
	if len(r.buffer) == 0 {
		r.hasOpenGap = false
		return
	}
	var lowestBuffered uint64 = ^uint64(0)
	for seq := range r.buffer {
		if seq < lowestBuffered {
			lowestBuffered = seq
		}
	}
	// lowestBuffered is guaranteed > nextSeq (we only buffer seqs > nextSeq),
	// so gapEnd doesn't underflow.
	gapEnd := lowestBuffered - 1
	rng := NakRange{StartSeq: r.nextSeq, EndSeq: gapEnd}
	r.naks++
	if r.onNak != nil {
		r.onNak(rng)
	}
	r.gapSince = r.now()
	r.gapDeadline = r.gapSince.Add(r.gapTimeout)
}

// bufferedBytes returns the live byte count of the out-of-order buffer.
func (r *Reassembler) bufferedBytes() int {
	n := 0
	for _, v := range r.buffer {
		n += len(v)
	}
	return n
}

// evictHighest drops the highest-seq buffered payload when we hit the
// OOM guard. We prefer dropping a buffered entry over the new arrival
// because the NAK loop can re-fetch the buffered seq.
func (r *Reassembler) evictHighest() {
	if len(r.buffer) == 0 {
		return
	}
	var highest uint64 = r.nextSeq
	for seq := range r.buffer {
		if seq > highest {
			highest = seq
		}
	}
	delete(r.buffer, highest)
	r.droppedStale++
}
