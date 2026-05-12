// Reassembler tests. The Dart side (`test/bonded/bonded_reassembler_test.dart`)
// is the spec — these tests pin the same invariants in Go so the relay's
// behaviour stays observably identical to the on-device decoder.

package bonded

import (
	"bytes"
	"testing"
	"time"
)

// recorder is a tiny harness that captures emitted payloads and NAKs from
// the reassembler. We expose Reset so individual subtests can re-use one
// recorder across scenarios.
type recorder struct {
	out []byte
	nak []NakRange
}

func (r *recorder) onOutbound(p []byte) { r.out = append(r.out, p...) }
func (r *recorder) onNak(n NakRange)    { r.nak = append(r.nak, n) }
func (r *recorder) reset()              { r.out = nil; r.nak = nil }

// fakeClock advances on demand so gap-timeout firing is deterministic.
type fakeClock struct{ t time.Time }

func (f *fakeClock) now() time.Time      { return f.t }
func (f *fakeClock) advance(d time.Duration) { f.t = f.t.Add(d) }

func newClock() *fakeClock {
	return &fakeClock{t: time.Date(2026, 5, 11, 0, 0, 0, 0, time.UTC)}
}

func TestReassembler_InOrder(t *testing.T) {
	rec := &recorder{}
	r := NewReassembler(ReassemblerConfig{})
	r.SetOutbound(rec.onOutbound)
	r.SetNak(rec.onNak)
	for i := uint64(0); i < 5; i++ {
		r.OnPayload(i, []byte{byte(i)})
	}
	want := []byte{0, 1, 2, 3, 4}
	if !bytes.Equal(rec.out, want) {
		t.Errorf("emit order: got %v want %v", rec.out, want)
	}
	if len(rec.nak) != 0 {
		t.Errorf("unexpected NAKs: %v", rec.nak)
	}
	s := r.Snapshot()
	if s.NextExpectedSeq != 5 || s.Delivered != 5 {
		t.Errorf("bad snapshot: %+v", s)
	}
}

func TestReassembler_OutOfOrderHole_Reorders(t *testing.T) {
	rec := &recorder{}
	r := NewReassembler(ReassemblerConfig{})
	r.SetOutbound(rec.onOutbound)
	// Deliver 0, then 2 (hole at 1), then 1 → expect 0,1,2 in order.
	r.OnPayload(0, []byte{0})
	r.OnPayload(2, []byte{2})
	if !bytes.Equal(rec.out, []byte{0}) {
		t.Fatalf("after 0+2 expected only 0, got %v", rec.out)
	}
	r.OnPayload(1, []byte{1})
	if !bytes.Equal(rec.out, []byte{0, 1, 2}) {
		t.Fatalf("after closing hole expected 0,1,2 got %v", rec.out)
	}
	s := r.Snapshot()
	if s.BufferedCount != 0 {
		t.Errorf("expected empty buffer, got %d", s.BufferedCount)
	}
}

func TestReassembler_GapTimeout_EmitsNak(t *testing.T) {
	rec := &recorder{}
	clock := newClock()
	r := NewReassembler(ReassemblerConfig{
		GapTimeout: 50 * time.Millisecond,
		Now:        clock.now,
	})
	r.SetOutbound(rec.onOutbound)
	r.SetNak(rec.onNak)

	// Open a hole: deliver 0 then 5 (4 missing seqs).
	r.OnPayload(0, []byte{0})
	r.OnPayload(5, []byte{5})

	// Before timeout — no NAK.
	r.Tick()
	if len(rec.nak) != 0 {
		t.Fatalf("premature NAK: %v", rec.nak)
	}

	// Cross the deadline.
	clock.advance(60 * time.Millisecond)
	r.Tick()
	if len(rec.nak) != 1 {
		t.Fatalf("expected 1 NAK, got %d (%v)", len(rec.nak), rec.nak)
	}
	got := rec.nak[0]
	if got.StartSeq != 1 || got.EndSeq != 4 {
		t.Errorf("wrong NAK range: %+v", got)
	}

	// Filling the hole stops further NAKs.
	r.OnPayload(1, []byte{1})
	r.OnPayload(2, []byte{2})
	r.OnPayload(3, []byte{3})
	r.OnPayload(4, []byte{4})
	clock.advance(time.Second)
	r.Tick()
	if len(rec.nak) != 1 {
		t.Fatalf("expected NAKs to stop after hole filled, got %d", len(rec.nak))
	}
	want := []byte{0, 1, 2, 3, 4, 5}
	if !bytes.Equal(rec.out, want) {
		t.Errorf("final emit: got %v want %v", rec.out, want)
	}
}

func TestReassembler_DuplicateBeforeNextSeq_Dropped(t *testing.T) {
	rec := &recorder{}
	r := NewReassembler(ReassemblerConfig{})
	r.SetOutbound(rec.onOutbound)
	r.OnPayload(0, []byte{0})
	r.OnPayload(1, []byte{1})
	// Replay of seq 0 — must be dropped, not re-emitted.
	r.OnPayload(0, []byte{0})
	if !bytes.Equal(rec.out, []byte{0, 1}) {
		t.Errorf("dup re-emitted: %v", rec.out)
	}
	if got := r.Snapshot().DroppedDup; got != 1 {
		t.Errorf("expected 1 dup drop, got %d", got)
	}
}

func TestReassembler_OutsideWindow_DroppedStale(t *testing.T) {
	rec := &recorder{}
	r := NewReassembler(ReassemblerConfig{
		WindowSize: 16,
	})
	r.SetOutbound(rec.onOutbound)
	// nextSeq starts at 0. Anything ≥ windowSize is too far ahead.
	r.OnPayload(uint64(16), []byte{99})
	if len(rec.out) != 0 {
		t.Errorf("emitted past-window payload: %v", rec.out)
	}
	if got := r.Snapshot().DroppedStale; got != 1 {
		t.Errorf("expected 1 stale drop, got %d", got)
	}
	// A fresh seq 0 still works after a stale drop.
	r.OnPayload(0, []byte{0xFE})
	if !bytes.Equal(rec.out, []byte{0xFE}) {
		t.Errorf("post-stale emit failed: %v", rec.out)
	}
}

func TestReassembler_MaxBufferedBytes_EvictsHighest(t *testing.T) {
	rec := &recorder{}
	r := NewReassembler(ReassemblerConfig{
		MaxBufferedBytes: 16,
	})
	r.SetOutbound(rec.onOutbound)
	// Open a hole at seq 0 so the buffer holds the next two arrivals.
	r.OnPayload(1, bytes.Repeat([]byte{0xA}, 8))
	r.OnPayload(2, bytes.Repeat([]byte{0xB}, 8))
	// Third arrival would push us to 24 B (> 16 cap); the OOM guard
	// MUST evict the highest-seq buffered payload (seq 2) before
	// inserting seq 3. We assert on the snapshot rather than on emit
	// order — eviction inherently breaks downstream contiguity, but the
	// invariant we care about is "buffer never exceeds the cap".
	r.OnPayload(3, bytes.Repeat([]byte{0xC}, 8))
	s := r.Snapshot()
	if s.BufferedCount != 2 {
		t.Errorf("expected 2 buffered after eviction, got %d", s.BufferedCount)
	}
	if s.BufferedBytes > 16 {
		t.Errorf("buffer exceeded cap: %d > 16", s.BufferedBytes)
	}
	if s.DroppedStale < 1 {
		t.Errorf("expected at least 1 stale eviction, got %d", s.DroppedStale)
	}
}
