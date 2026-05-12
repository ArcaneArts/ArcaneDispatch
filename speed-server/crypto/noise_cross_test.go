package crypto

import (
	"encoding/hex"
	"testing"
)

// Cross-language Noise IK handshake vectors. These hex strings are
// asserted from the canonical Go implementation and re-asserted from
// the Dart and Swift mirrors (see `test/crypto/noise_cross_test.dart`
// and the upcoming Swift `NoiseCrossTests.swift`).
//
// Inputs:
//
//	initiator static seed:   01 followed by 31 zero bytes
//	initiator ephemeral:     02 followed by 31 zero bytes
//	responder static seed:   03 followed by 31 zero bytes
//	responder ephemeral:     04 followed by 31 zero bytes
//	message1 payload:        "hello server"
//	message2 payload:        "hello client"
//
// Every other side of the wire MUST produce the same hex strings byte
// for byte. If one of them diverges, the protocol has drifted; that's a
// release-blocking bug.

const (
	crossInitStaticSeed = "0100000000000000000000000000000000000000000000000000000000000000"
	crossInitEphSeed    = "0200000000000000000000000000000000000000000000000000000000000000"
	crossRespStaticSeed = "0300000000000000000000000000000000000000000000000000000000000000"
	crossRespEphSeed    = "0400000000000000000000000000000000000000000000000000000000000000"
	crossMsg1PayloadHex = "68656c6c6f20736572766572" // "hello server"
	crossMsg2PayloadHex = "68656c6c6f20636c69656e74" // "hello client"

	// Locked wire vectors captured from the canonical Go output. Any
	// future change to clamping, HKDF, mixHash, or AEAD framing will
	// flip these hex strings.
	expectedMsg1Hex = "2fe57da347cd62431528daac5fbb290730fff684afc4cfc2ed90995f58cb3b74" +
		"f3d31b3ecff438842427efae43f49ef54d63e7b8eb23c659f511beea7ee60605" +
		"aebde724350d862a7d8c19e639ee18c9cd51ecb9e4f4948f626959d21eb4c5b2" +
		"e6b4f3e64e37e230a5e49603"
	expectedMsg2Hex = "2fe57da347cd62431528daac5fbb290730fff684afc4cfc2ed90995f58cb3b74" +
		"1550103823047d8ea658eadbd61f240eff8a48f1ef4e79213b9801b6"
	expectedInitSendKeyHex = "80259c98a8360079177a63edcd0a05ea335b9ba51ce9a2b85f09d5dd89374c6f"
	expectedInitRecvKeyHex = "60eaa771f1e0b84abdfd8e36b7e12938d59b19eda1bf69dddeaadeb321531d5b"
	expectedFirstSealedHex = "da02010000000000000000009ecd2ced2bdf75a2cffc10c4d9bdfe510c2bfa225e"
)

func TestNoiseIK_CrossLanguageVectors(t *testing.T) {
	mustHex := func(s string) []byte {
		b, err := hex.DecodeString(s)
		if err != nil {
			t.Fatalf("hex decode %q: %v", s, err)
		}
		return b
	}
	seed := func(s string) [32]byte {
		b := mustHex(s)
		var out [32]byte
		copy(out[:], b)
		return out
	}

	initStatic := KeypairFromSeed(seed(crossInitStaticSeed))
	respStatic := KeypairFromSeed(seed(crossRespStaticSeed))

	init, err := NewInitiator(initStatic, respStatic.Public)
	if err != nil {
		t.Fatalf("NewInitiator: %v", err)
	}
	init.SetTestEphemeral(seed(crossInitEphSeed))

	resp, err := NewResponder(respStatic)
	if err != nil {
		t.Fatalf("NewResponder: %v", err)
	}
	resp.SetTestEphemeral(seed(crossRespEphSeed))

	msg1, err := init.WriteMessage1(mustHex(crossMsg1PayloadHex))
	if err != nil {
		t.Fatalf("WriteMessage1: %v", err)
	}
	if got := hex.EncodeToString(msg1); got != expectedMsg1Hex {
		t.Fatalf("msg1 mismatch\n got: %s\nwant: %s", got, expectedMsg1Hex)
	}

	gotPayload, err := resp.ReadMessage1(msg1)
	if err != nil {
		t.Fatalf("ReadMessage1: %v", err)
	}
	if hex.EncodeToString(gotPayload) != crossMsg1PayloadHex {
		t.Fatalf("payload mismatch after ReadMessage1: %x", gotPayload)
	}

	msg2, respT, err := resp.WriteMessage2(mustHex(crossMsg2PayloadHex))
	if err != nil {
		t.Fatalf("WriteMessage2: %v", err)
	}
	if got := hex.EncodeToString(msg2); got != expectedMsg2Hex {
		t.Fatalf("msg2 mismatch\n got: %s\nwant: %s", got, expectedMsg2Hex)
	}

	got2, initT, err := init.ReadMessage2(msg2)
	if err != nil {
		t.Fatalf("ReadMessage2: %v", err)
	}
	if hex.EncodeToString(got2) != crossMsg2PayloadHex {
		t.Fatalf("payload2 mismatch: %x", got2)
	}

	if got := hex.EncodeToString(initT.sendKey[:]); got != expectedInitSendKeyHex {
		t.Fatalf("init sendKey mismatch\n got: %s\nwant: %s", got, expectedInitSendKeyHex)
	}
	if got := hex.EncodeToString(initT.recvKey[:]); got != expectedInitRecvKeyHex {
		t.Fatalf("init recvKey mismatch\n got: %s\nwant: %s", got, expectedInitRecvKeyHex)
	}
	// Responder keys are the mirror image.
	if !bytesEqual(initT.sendKey[:], respT.recvKey[:]) {
		t.Fatalf("init.send ↔ resp.recv must match")
	}
	if !bytesEqual(initT.recvKey[:], respT.sendKey[:]) {
		t.Fatalf("init.recv ↔ resp.send must match")
	}

	wire, err := Seal(initT, []byte("hello"))
	if err != nil {
		t.Fatalf("Seal: %v", err)
	}
	if got := hex.EncodeToString(wire); got != expectedFirstSealedHex {
		t.Fatalf("sealed mismatch\n got: %s\nwant: %s", got, expectedFirstSealedHex)
	}

	hdr, err := DecodeSealedHeader(wire[:SealedHeaderSize])
	if err != nil {
		t.Fatalf("DecodeSealedHeader: %v", err)
	}
	plain, err := Open(respT, hdr, wire[SealedHeaderSize:])
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if string(plain) != "hello" {
		t.Fatalf("sealed plain mismatch: %q", plain)
	}
}

// bytesEqual avoids the import bloat of `bytes` for a single equality.
func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
