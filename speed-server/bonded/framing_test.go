// Cross-language framing vectors for the bonded transport.
//
// The hex strings here are the on-wire bytes the Dart and Swift encoders
// MUST also produce for the same inputs. If you change the wire format,
// update these vectors AND the matching tests in:
//
//   * test/bonded/bonded_framing_test.dart
//   * (forthcoming) macos/ArcaneDispatchTunnelTests/BondedFramingTests.swift
//
// Then bump `ProtocolVersion` in all three places.

package bonded

import (
	"bytes"
	"encoding/hex"
	"errors"
	"testing"
)

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("bad hex constant in test: %v", err)
	}
	return b
}

// TestEncode_KnownVectors locks the wire bytes for a representative set of
// frames so any encoder drift between the three implementations is caught
// in CI rather than in the field.
func TestEncode_KnownVectors(t *testing.T) {
	tests := []struct {
		name string
		in   EncodeOptions
		want string // hex
	}{
		{
			name: "empty payload, all zero",
			in:   EncodeOptions{SessionID: 0, Seq: 0, LinkID: 0, Flags: 0},
			//   magic ver flg sessionId(8)        seq(8)              link  plen
			want: "DA01" + "01" + "00" +
				"0000000000000000" + "0000000000000000" + "0000" + "0000",
		},
		{
			name: "high-bit u64 sessionId, payload",
			in: EncodeOptions{
				SessionID: 0xABCD000000000001,
				Seq:       0x0000000000000005,
				LinkID:    0x0001,
				Flags:     FlagAck,
				Payload:   []byte{0x10, 0x20, 0x30, 0x40},
			},
			want: "DA01" + "01" + "01" +
				"ABCD000000000001" + "0000000000000005" + "0001" + "0004" +
				"10203040",
		},
		{
			name: "keepalive with inflight counter (u64 LE body)",
			in: EncodeOptions{
				SessionID: 0x0102030405060708,
				Seq:       0,
				LinkID:    7,
				Flags:     FlagKeepalive,
				// Spec: keepalive payload is u64 little-endian inflight counter.
				Payload: []byte{0x99, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
			},
			want: "DA01" + "01" + "04" +
				"0102030405060708" + "0000000000000000" + "0007" + "0008" +
				"9900000000000000",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Encode(tt.in)
			if err != nil {
				t.Fatalf("Encode: %v", err)
			}
			want := mustHex(t, tt.want)
			if !bytes.Equal(got, want) {
				t.Errorf("encoded bytes mismatch\n got=%X\nwant=%X", got, want)
			}
		})
	}
}

// TestRoundTrip_RandomShape exercises the encoder/decoder with a
// representative range of payload sizes, including the boundary cases
// (0, 1, MaxPayload-1, MaxPayload).
func TestRoundTrip_RandomShape(t *testing.T) {
	sizes := []int{0, 1, 23, 24, 100, MaxPayload - 1, MaxPayload}
	for _, n := range sizes {
		t.Run("size", func(t *testing.T) {
			payload := make([]byte, n)
			for i := range payload {
				payload[i] = byte(i * 31)
			}
			frame, err := Encode(EncodeOptions{
				SessionID: 0xDEADBEEFCAFEBABE,
				Seq:       12345,
				LinkID:    42,
				Flags:     FlagAck | FlagRetransmit,
				Payload:   payload,
			})
			if err != nil {
				t.Fatalf("Encode: %v", err)
			}
			got, err := Decode(frame)
			if err != nil {
				t.Fatalf("Decode: %v", err)
			}
			if got.SessionID != 0xDEADBEEFCAFEBABE {
				t.Errorf("SessionID mismatch: 0x%x", got.SessionID)
			}
			if got.Seq != 12345 || got.LinkID != 42 {
				t.Errorf("seq/link mismatch")
			}
			if !got.IsAck() || !got.IsRetransmit() {
				t.Errorf("flags mismatch")
			}
			if !bytes.Equal(got.Payload, payload) {
				t.Errorf("payload mismatch")
			}
		})
	}
}

// TestEncode_RejectsOversized makes sure callers can't accidentally ship a
// frame bigger than the IPv6 conservative MTU.
func TestEncode_RejectsOversized(t *testing.T) {
	_, err := Encode(EncodeOptions{
		Payload: make([]byte, MaxPayload+1),
	})
	if !errors.Is(err, ErrPayloadTooLarge) {
		t.Fatalf("want ErrPayloadTooLarge, got %v", err)
	}
}

// TestEncode_RejectsReservedBits guards against forward-incompatible
// flag values leaking onto the wire.
func TestEncode_RejectsReservedBits(t *testing.T) {
	_, err := Encode(EncodeOptions{Flags: 0x80}) // bit 7, reserved
	if !errors.Is(err, ErrReservedFlags) {
		t.Fatalf("want ErrReservedFlags, got %v", err)
	}
}

// TestDecode_BadMagic makes sure stray packets from unrelated protocols
// (e.g. a Wireguard handshake landing on the wrong port) decode cleanly
// to ErrBadMagic so the relay can drop them.
func TestDecode_BadMagic(t *testing.T) {
	bytes := make([]byte, HeaderSize)
	bytes[0] = 0xCA
	bytes[1] = 0xFE
	_, err := Decode(bytes)
	if !errors.Is(err, ErrBadMagic) {
		t.Fatalf("want ErrBadMagic, got %v", err)
	}
}

// TestDecode_UnsupportedVersion catches forward-incompatible peers.
func TestDecode_UnsupportedVersion(t *testing.T) {
	frame, err := Encode(EncodeOptions{SessionID: 1})
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	frame[2] = 99 // overwrite version
	_, err = Decode(frame)
	if !errors.Is(err, ErrUnsupportedVer) {
		t.Fatalf("want ErrUnsupportedVer, got %v", err)
	}
}

// TestDecode_Truncated drops short reads cleanly. UDP reads that span
// fragments shouldn't reach Decode (we'd have already discarded them at
// the socket layer), but TCP framing might end up truncated mid-stream,
// so we still want a typed error.
func TestDecode_Truncated(t *testing.T) {
	frame, err := Encode(EncodeOptions{
		SessionID: 1,
		Payload:   bytes.Repeat([]byte{0xAB}, 100),
	})
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}
	short := frame[:HeaderSize+50] // claim 100 B, give 50
	_, err = Decode(short)
	if !errors.Is(err, ErrTruncated) {
		t.Fatalf("want ErrTruncated, got %v", err)
	}
}

// TestDecode_ShortRead handles "below header size" packets — typically
// a probe from a misconfigured client.
func TestDecode_ShortRead(t *testing.T) {
	_, err := Decode([]byte{0xDA, 0x01, 0x01})
	if !errors.Is(err, ErrShortRead) {
		t.Fatalf("want ErrShortRead, got %v", err)
	}
}
