// Anti-replay sliding window for the bonded transport.
//
// We follow the same construction as RFC 4303 §3.4.3 ("Anti-Replay
// Window"): a bitmap of size [WindowSize] that tracks which of the last
// `WindowSize` nonces have already been seen. New nonces shift the
// window forward; anything older than the window's left edge is
// rejected.
//
// Threading: a Window is single-owner. The relay's per-session worker
// already serialises packet processing, so a mutex would just slow the
// hot path. If you ever share one across goroutines, wrap it.

package crypto

import "errors"

// DefaultReplayWindow is the size the spec calls for (Phase 9 — 1024).
// Wide enough to absorb realistic out-of-order delivery on a 100 ms RTT
// 100 Mbps link without false rejects.
const DefaultReplayWindow = 1024

// ErrReplay is returned by [ReplayWindow.Check] when the supplied nonce
// has already been seen.
var ErrReplay = errors.New("crypto: replay detected")

// ErrTooOld is returned when the nonce is older than the window's left
// edge (so we can't tell if it was already seen and must drop).
var ErrTooOld = errors.New("crypto: nonce predates replay window")

// ReplayWindow tracks the highest nonce seen plus a bitmap of the last
// `Size` nonces. Bit `i` of the bitmap is set iff `(highest - i)` was
// observed.
type ReplayWindow struct {
	size    int
	highest uint64
	primed  bool
	bitmap  []uint64 // each u64 covers 64 bits
}

// NewReplayWindow allocates a window of the given size (in entries). A
// size of 0 falls back to [DefaultReplayWindow].
func NewReplayWindow(size int) *ReplayWindow {
	if size <= 0 {
		size = DefaultReplayWindow
	}
	words := (size + 63) / 64
	return &ReplayWindow{
		size:   size,
		bitmap: make([]uint64, words),
	}
}

// Check inspects `nonce` and either marks it seen (returning nil) or
// returns an error explaining the reject reason. The first call is
// always accepted regardless of nonce value.
func (w *ReplayWindow) Check(nonce uint64) error {
	if !w.primed {
		w.primed = true
		w.highest = nonce
		w.setBit(0)
		return nil
	}
	if nonce > w.highest {
		shift := nonce - w.highest
		w.shiftLeft(shift)
		w.highest = nonce
		w.setBit(0)
		return nil
	}
	offset := w.highest - nonce
	if int(offset) >= w.size {
		return ErrTooOld
	}
	if w.testBit(int(offset)) {
		return ErrReplay
	}
	w.setBit(int(offset))
	return nil
}

// Highest returns the highest nonce ever accepted (or zero when no
// nonce has been seen).
func (w *ReplayWindow) Highest() uint64 { return w.highest }

// shiftLeft rotates the bitmap so the new "bit 0" represents the new
// `highest`. Bits that fall off the right (the old window edge) are
// discarded.
func (w *ReplayWindow) shiftLeft(by uint64) {
	if by >= uint64(w.size) {
		for i := range w.bitmap {
			w.bitmap[i] = 0
		}
		return
	}
	bigShift := int(by / 64)
	smallShift := int(by % 64)
	// Move whole words first.
	if bigShift > 0 {
		for i := len(w.bitmap) - 1; i >= 0; i-- {
			src := i - bigShift
			if src < 0 {
				w.bitmap[i] = 0
			} else {
				w.bitmap[i] = w.bitmap[src]
			}
		}
	}
	// Then bit-level shift left within each word.
	if smallShift > 0 {
		carry := uint64(0)
		for i := 0; i < len(w.bitmap); i++ {
			newCarry := w.bitmap[i] >> (64 - smallShift)
			w.bitmap[i] = (w.bitmap[i] << smallShift) | carry
			carry = newCarry
		}
	}
}

func (w *ReplayWindow) setBit(i int) {
	if i >= w.size {
		return
	}
	w.bitmap[i/64] |= uint64(1) << uint(i%64)
}

func (w *ReplayWindow) testBit(i int) bool {
	if i >= w.size {
		return false
	}
	return w.bitmap[i/64]&(uint64(1)<<uint(i%64)) != 0
}
