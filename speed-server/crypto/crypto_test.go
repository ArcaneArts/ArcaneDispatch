package crypto

import (
	"bytes"
	"testing"
)

// initiator / responder seeds chosen so both sides are deterministic.
// We never use these outside tests — they're trivially insecure.
var (
	initiatorStaticSeed  = [32]byte{0x01, 0x01, 0x01, 0x01}
	initiatorEphSeed     = [32]byte{0x02, 0x02, 0x02, 0x02}
	responderStaticSeed  = [32]byte{0x03, 0x03, 0x03, 0x03}
	responderEphSeed     = [32]byte{0x04, 0x04, 0x04, 0x04}
)

// runHandshake drives an IK exchange between an initiator and a responder
// using deterministic test seeds. Returns the post-handshake Transport
// for both sides plus the application payloads each side received.
func runHandshake(t *testing.T, msg1Payload, msg2Payload []byte) (
	*Transport, *Transport, []byte, []byte,
) {
	t.Helper()
	initStatic := KeypairFromSeed(initiatorStaticSeed)
	respStatic := KeypairFromSeed(responderStaticSeed)

	initHS, err := NewInitiator(initStatic, respStatic.Public)
	if err != nil {
		t.Fatalf("NewInitiator: %v", err)
	}
	initHS.SetTestEphemeral(initiatorEphSeed)

	respHS, err := NewResponder(respStatic)
	if err != nil {
		t.Fatalf("NewResponder: %v", err)
	}
	respHS.SetTestEphemeral(responderEphSeed)

	msg1, err := initHS.WriteMessage1(msg1Payload)
	if err != nil {
		t.Fatalf("WriteMessage1: %v", err)
	}
	gotPayload1, err := respHS.ReadMessage1(msg1)
	if err != nil {
		t.Fatalf("ReadMessage1: %v", err)
	}

	msg2, respT, err := respHS.WriteMessage2(msg2Payload)
	if err != nil {
		t.Fatalf("WriteMessage2: %v", err)
	}
	gotPayload2, initT, err := initHS.ReadMessage2(msg2)
	if err != nil {
		t.Fatalf("ReadMessage2: %v", err)
	}

	return initT, respT, gotPayload1, gotPayload2
}

func TestHandshake_PayloadsRoundTrip(t *testing.T) {
	_, _, got1, got2 := runHandshake(t,
		[]byte("hello server"), []byte("hello client"))
	if string(got1) != "hello server" {
		t.Errorf("msg1 payload: got %q", got1)
	}
	if string(got2) != "hello client" {
		t.Errorf("msg2 payload: got %q", got2)
	}
}

func TestHandshake_RemoteStaticRecovered(t *testing.T) {
	initStatic := KeypairFromSeed(initiatorStaticSeed)
	respStatic := KeypairFromSeed(responderStaticSeed)
	initHS, _ := NewInitiator(initStatic, respStatic.Public)
	initHS.SetTestEphemeral(initiatorEphSeed)
	respHS, _ := NewResponder(respStatic)
	respHS.SetTestEphemeral(responderEphSeed)
	msg1, _ := initHS.WriteMessage1(nil)
	if _, err := respHS.ReadMessage1(msg1); err != nil {
		t.Fatalf("ReadMessage1: %v", err)
	}
	if respHS.RemoteStatic() != initStatic.Public {
		t.Fatalf("responder did not learn initiator's static")
	}
}

func TestTransport_SealAndOpen(t *testing.T) {
	initT, respT, _, _ := runHandshake(t, nil, nil)

	plaintext := []byte("hello over the wire")
	ad := []byte("frame-header")

	nonce, ct, err := initT.Seal(ad, plaintext)
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if nonce != 0 {
		t.Fatalf("first send nonce should be 0, got %d", nonce)
	}
	got, err := respT.Open(nonce, ad, ct)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if !bytes.Equal(got, plaintext) {
		t.Fatalf("plaintext round-trip mismatch: %q != %q", got, plaintext)
	}
}

func TestTransport_TamperingFailsAEAD(t *testing.T) {
	initT, respT, _, _ := runHandshake(t, nil, nil)
	_, ct, err := initT.Seal([]byte("ad"), []byte("secret"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	// Flip a bit.
	ct[0] ^= 0x80
	if _, err := respT.Open(0, []byte("ad"), ct); err == nil {
		t.Fatalf("Open should reject tampered ciphertext")
	}
}

func TestTransport_NonceIncrements(t *testing.T) {
	initT, respT, _, _ := runHandshake(t, nil, nil)
	for i := 0; i < 5; i++ {
		nonce, ct, err := initT.Seal(nil, []byte{byte(i)})
		if err != nil {
			t.Fatalf("seal %d: %v", i, err)
		}
		if nonce != uint64(i) {
			t.Fatalf("nonce[%d]=%d", i, nonce)
		}
		plain, err := respT.Open(nonce, nil, ct)
		if err != nil {
			t.Fatalf("open %d: %v", i, err)
		}
		if len(plain) != 1 || plain[0] != byte(i) {
			t.Fatalf("plaintext[%d]=%v", i, plain)
		}
	}
	if initT.SendNonce() != 5 {
		t.Fatalf("send nonce after 5 seals = %d", initT.SendNonce())
	}
}

func TestHandshake_RejectsLargePayload(t *testing.T) {
	initStatic := KeypairFromSeed(initiatorStaticSeed)
	respStatic := KeypairFromSeed(responderStaticSeed)
	initHS, _ := NewInitiator(initStatic, respStatic.Public)
	initHS.SetTestEphemeral(initiatorEphSeed)
	huge := make([]byte, MaxHandshakePayload+1)
	if _, err := initHS.WriteMessage1(huge); err == nil {
		t.Fatalf("WriteMessage1 should reject oversized payload")
	}
}

// ----- Replay window ------------------------------------------------------

func TestReplayWindow_AcceptsNewNonces(t *testing.T) {
	w := NewReplayWindow(64)
	for i := uint64(0); i < 64; i++ {
		if err := w.Check(i); err != nil {
			t.Fatalf("Check(%d): %v", i, err)
		}
	}
}

func TestReplayWindow_RejectsReplay(t *testing.T) {
	w := NewReplayWindow(64)
	if err := w.Check(42); err != nil {
		t.Fatalf("first check: %v", err)
	}
	if err := w.Check(42); err != ErrReplay {
		t.Fatalf("expected ErrReplay, got %v", err)
	}
}

func TestReplayWindow_AcceptsOutOfOrderWithinWindow(t *testing.T) {
	w := NewReplayWindow(32)
	if err := w.Check(10); err != nil {
		t.Fatalf("check 10: %v", err)
	}
	// 5 < 10 but within window of 32 — should be accepted.
	if err := w.Check(5); err != nil {
		t.Fatalf("check 5: %v", err)
	}
	if err := w.Check(5); err != ErrReplay {
		t.Fatalf("duplicate 5: %v", err)
	}
}

func TestReplayWindow_RejectsAncientNonces(t *testing.T) {
	w := NewReplayWindow(8)
	// Prime the window at 100.
	if err := w.Check(100); err != nil {
		t.Fatalf("prime: %v", err)
	}
	// 80 is way outside the 8-wide window.
	if err := w.Check(80); err != ErrTooOld {
		t.Fatalf("expected ErrTooOld, got %v", err)
	}
}

func TestReplayWindow_HandlesLargeShift(t *testing.T) {
	w := NewReplayWindow(128)
	if err := w.Check(0); err != nil {
		t.Fatalf("check 0: %v", err)
	}
	// Skip way ahead.
	if err := w.Check(1_000_000); err != nil {
		t.Fatalf("big jump: %v", err)
	}
	if err := w.Check(0); err != ErrTooOld {
		t.Fatalf("ancient 0 should be ErrTooOld, got %v", err)
	}
	// New near the high water mark should still be accepted.
	if err := w.Check(999_999); err != nil {
		t.Fatalf("recent 999999: %v", err)
	}
}

// ----- Sealed frame -------------------------------------------------------

func TestSeal_RoundTrip(t *testing.T) {
	initT, respT, _, _ := runHandshake(t, nil, nil)
	wire, err := Seal(initT, []byte("payload"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if len(wire) < SealedHeaderSize {
		t.Fatalf("wire too short: %d", len(wire))
	}
	hdr, err := DecodeSealedHeader(wire[:SealedHeaderSize])
	if err != nil {
		t.Fatalf("DecodeSealedHeader: %v", err)
	}
	if hdr.Magic != SealedMagic {
		t.Fatalf("magic=%04x", hdr.Magic)
	}
	if hdr.Version != SealedVersion {
		t.Fatalf("version=%d", hdr.Version)
	}
	if hdr.Nonce != 0 {
		t.Fatalf("nonce=%d, expected 0 for first sent frame", hdr.Nonce)
	}
	plain, err := Open(respT, hdr, wire[SealedHeaderSize:])
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if string(plain) != "payload" {
		t.Fatalf("plaintext mismatch: %q", plain)
	}
}

func TestSeal_TamperingFails(t *testing.T) {
	initT, respT, _, _ := runHandshake(t, nil, nil)
	wire, _ := Seal(initT, []byte("payload"))
	// Flip a bit in the header (nonce byte).
	wire[4] ^= 0x80
	hdr, err := DecodeSealedHeader(wire[:SealedHeaderSize])
	if err != nil {
		t.Fatalf("decode header: %v", err)
	}
	if _, err := Open(respT, hdr, wire[SealedHeaderSize:]); err == nil {
		t.Fatalf("Open should fail on tampered header")
	}
}

func TestDecodeSealedHeader_RejectsGarbage(t *testing.T) {
	if _, err := DecodeSealedHeader([]byte{0, 0, 0}); err == nil {
		t.Fatalf("expected short error")
	}
	bogus := make([]byte, SealedHeaderSize)
	bogus[0] = 0xDE
	bogus[1] = 0xAD
	if _, err := DecodeSealedHeader(bogus); err == nil {
		t.Fatalf("expected bad-magic error")
	}
}
