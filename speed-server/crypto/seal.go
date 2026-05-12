// Sealed-frame layer for the bonded transport.
//
// A sealed frame wraps a plaintext bonded frame in a Noise transport
// AEAD seal so it can be safely shipped over UDP. Wire layout:
//
//	┌─────── sealed header (12 B) ───────┐
//	│ magic      u16  (0xDA02)           │
//	│ version    u8   (1)                │
//	│ flags      u8   (reserved)         │
//	│ nonce      u64  send counter       │
//	└────────────────────────────────────┘
//	┌──── ciphertext (variable) ─────────┐
//	│ AEAD(plaintext)                    │
//	└────────────────────────────────────┘
//
// The AEAD additional-data is the 12-byte header so an attacker who
// tampers with the nonce or flags fails the AEAD check on decrypt.
//
// We deliberately keep the magic byte and version *separate* from the
// inner bonded frame's magic / version. This means a recipient who
// hasn't completed the handshake (or has the wrong keys) can still tell
// a sealed packet apart from a non-sealed one and respond accordingly.

package crypto

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	// SealedMagic is the first two bytes of every sealed frame. Distinct
	// from the bonded plaintext magic so misrouted packets get rejected
	// at the right layer.
	SealedMagic uint16 = 0xDA02

	// SealedVersion is the wire-format version. Bump on layout breaks.
	SealedVersion uint8 = 1

	// SealedHeaderSize is the fixed-length prefix in bytes.
	SealedHeaderSize = 12
)

// Errors returned by Seal / Open. Distinct values let the relay's stats
// counters bucket failure modes (bad magic vs replay vs AEAD failure).
var (
	ErrSealedShort        = errors.New("crypto: sealed frame too short")
	ErrSealedBadMagic     = errors.New("crypto: bad sealed magic")
	ErrSealedBadVersion   = errors.New("crypto: unsupported sealed version")
	ErrSealedReservedFlag = errors.New("crypto: reserved sealed flag bits set")
)

// SealedHeader is the decoded header of a sealed frame. The relay reads
// this before invoking AEAD so the per-session lookup can happen on a
// trusted nonce.
type SealedHeader struct {
	Magic   uint16
	Version uint8
	Flags   uint8
	Nonce   uint64
}

// Seal wraps `plaintext` with the supplied Transport's send key. Returns
// the full wire bytes (header + AEAD ciphertext).
//
// `t` MUST be a Transport from a completed handshake (see noise.go). The
// returned nonce is also the integer counter from `t.SendNonce()`.
func Seal(t *Transport, plaintext []byte) ([]byte, error) {
	hdr := make([]byte, SealedHeaderSize)
	binary.BigEndian.PutUint16(hdr[0:2], SealedMagic)
	hdr[2] = SealedVersion
	hdr[3] = 0
	// Reserve the nonce slot — we'll overwrite after Seal so the AD
	// matches what's on the wire.
	nonce, ct, err := t.Seal(nil, plaintext)
	if err != nil {
		return nil, fmt.Errorf("seal aead: %w", err)
	}
	binary.BigEndian.PutUint64(hdr[4:12], nonce)
	// Re-seal with the now-finalised header as AD. We discard the first
	// seal because we needed the nonce value before we could build the
	// header AD. Two-pass like this is cheaper than computing the nonce
	// manually — `t.Seal` already increments the counter atomically.
	// Roll back the counter and re-seal under the correct AD.
	t.sendNonce-- // reuse the previously consumed counter slot
	_, ct, err = t.Seal(hdr, plaintext)
	if err != nil {
		return nil, fmt.Errorf("seal aead retry: %w", err)
	}
	out := make([]byte, 0, SealedHeaderSize+len(ct))
	out = append(out, hdr...)
	out = append(out, ct...)
	return out, nil
}

// DecodeSealedHeader parses just the header from a sealed frame. Useful
// for the relay's dispatch loop where we want to look up the session by
// nonce before deciding to spend AEAD cycles.
func DecodeSealedHeader(buf []byte) (SealedHeader, error) {
	if len(buf) < SealedHeaderSize {
		return SealedHeader{},
			fmt.Errorf("%w: %d < %d", ErrSealedShort, len(buf), SealedHeaderSize)
	}
	h := SealedHeader{
		Magic:   binary.BigEndian.Uint16(buf[0:2]),
		Version: buf[2],
		Flags:   buf[3],
		Nonce:   binary.BigEndian.Uint64(buf[4:12]),
	}
	if h.Magic != SealedMagic {
		return SealedHeader{}, fmt.Errorf("%w: 0x%04x", ErrSealedBadMagic, h.Magic)
	}
	if h.Version != SealedVersion {
		return SealedHeader{}, fmt.Errorf("%w: %d", ErrSealedBadVersion, h.Version)
	}
	if h.Flags != 0 {
		return SealedHeader{}, fmt.Errorf("%w: 0x%02x", ErrSealedReservedFlag, h.Flags)
	}
	return h, nil
}

// Open verifies + decrypts a wire-format sealed frame, returning the
// plaintext bonded bytes. Caller MUST have already gated `hdr.Nonce`
// through a [ReplayWindow] to defeat replay attacks; Open only enforces
// the AEAD tag.
func Open(t *Transport, hdr SealedHeader, ciphertext []byte) ([]byte, error) {
	adBuf := make([]byte, SealedHeaderSize)
	binary.BigEndian.PutUint16(adBuf[0:2], hdr.Magic)
	adBuf[2] = hdr.Version
	adBuf[3] = hdr.Flags
	binary.BigEndian.PutUint64(adBuf[4:12], hdr.Nonce)
	plain, err := t.Open(hdr.Nonce, adBuf, ciphertext)
	if err != nil {
		return nil, fmt.Errorf("open aead: %w", err)
	}
	return plain, nil
}
