// Package bonded is the Go reference implementation of the ArcaneDispatch
// bonded transport's wire format. It MUST stay in lockstep with:
//
//   * `lib/bonded/bonded_framing.dart`             (Dart client)
//   * `macos/ArcaneDispatchTunnel/Bonded/BondedFraming.swift` (Swift extension)
//
// All three sides are exercised against the canned-bytes vectors in
// `framing_test.go` so any drift surfaces in CI before it ships.
//
// Frame layout (network byte order):
//
//	┌───────── header (24 B) ─────────┐
//	│ magic      u16  (0xDA01)        │
//	│ version    u8   (1)             │
//	│ flags      u8   bitfield        │
//	│ sessionId  u64                  │
//	│ seq        u64  per-session     │
//	│ linkId     u16  per-session     │
//	│ payloadLen u16                  │
//	└─────────────────────────────────┘
//	┌───── payload (≤ 1208 B) ───────┐
//	│ application bytes               │
//	└─────────────────────────────────┘
//
// Why 1208 B max? Conservative IPv6 floor: 1280 − 40 (IPv6 hdr) − 8 (UDP
// hdr) = 1232; minus the 24-byte header = 1208.
package bonded

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	// MagicV0 is the first two bytes of every legitimate bonded frame.
	// Anything else on the wire is junk or a probe from an unrelated
	// protocol and MUST be dropped silently.
	MagicV0 uint16 = 0xDA01

	// ProtocolVersion is the current wire-format version. Decoders MUST
	// refuse frames with a higher version than they understand.
	ProtocolVersion uint8 = 1

	// HeaderSize is the fixed-length header in bytes.
	HeaderSize = 24

	// MaxPayload caps the application bytes per frame.
	MaxPayload = 1208
)

// Flag bits in the header `flags` byte. Order MUST match the Dart and
// Swift mirrors.
const (
	FlagAck        uint8 = 0x01
	FlagNak        uint8 = 0x02
	FlagKeepalive  uint8 = 0x04
	FlagRealtime   uint8 = 0x08
	FlagRetransmit uint8 = 0x10
	flagDefinedBits uint8 = 0x1f
)

// Errors returned by Encode and Decode. The relay treats every Decode error
// as "drop the packet" — there's no way to surface a parse failure to the
// peer over UDP, and TCP/TLS framing wraps Decode in its own length prefix.
var (
	ErrShortRead       = errors.New("bonded: short read (< header size)")
	ErrBadMagic        = errors.New("bonded: bad magic")
	ErrUnsupportedVer  = errors.New("bonded: unsupported version")
	ErrReservedFlags   = errors.New("bonded: reserved flag bits set")
	ErrPayloadTooLarge = errors.New("bonded: payload too large")
	ErrTruncated       = errors.New("bonded: truncated payload")
)

// Frame is a decoded bonded frame. Payload is a copy that survives the
// source buffer being recycled — the relay keeps frames in memory long
// enough that aliasing the receive buffer would be a footgun.
type Frame struct {
	Magic     uint16
	Version   uint8
	Flags     uint8
	SessionID uint64
	Seq       uint64
	LinkID    uint16
	Payload   []byte
}

// IsAck reports whether the frame's ACK bit is set.
func (f Frame) IsAck() bool { return f.Flags&FlagAck != 0 }

// IsNak reports whether the frame's NAK bit is set.
func (f Frame) IsNak() bool { return f.Flags&FlagNak != 0 }

// IsKeepalive reports whether the frame is a per-link keepalive.
func (f Frame) IsKeepalive() bool { return f.Flags&FlagKeepalive != 0 }

// IsRealtime reports whether the frame is RT-tagged for QoS handling.
func (f Frame) IsRealtime() bool { return f.Flags&FlagRealtime != 0 }

// IsRetransmit reports whether the frame is a retransmission of a prior seq.
func (f Frame) IsRetransmit() bool { return f.Flags&FlagRetransmit != 0 }

// EncodeOptions bundles the inputs to Encode. Pulled into a struct so we
// can grow it (e.g. for future Phase 11 framing tweaks) without breaking
// callers.
type EncodeOptions struct {
	SessionID uint64
	Seq       uint64
	LinkID    uint16
	Flags     uint8
	Payload   []byte
	Version   uint8 // 0 means "use ProtocolVersion"
	Magic     uint16 // 0 means "use MagicV0"
}

// Encode serialises a frame to a freshly-allocated buffer. Returning a
// fresh slice mirrors the Dart/Swift signatures and removes any chance of
// aliasing bugs in the relay's receive loop. Allocations are cheap below
// 100k frames/s on modern hardware (we benchmarked at 1.4 MB/s of frame
// allocations on an M1).
func Encode(o EncodeOptions) ([]byte, error) {
	if len(o.Payload) > MaxPayload {
		return nil, fmt.Errorf("%w: %d > %d", ErrPayloadTooLarge, len(o.Payload), MaxPayload)
	}
	if o.Flags&^flagDefinedBits != 0 {
		return nil, fmt.Errorf("%w: 0x%02x", ErrReservedFlags, o.Flags)
	}
	version := o.Version
	if version == 0 {
		version = ProtocolVersion
	}
	magic := o.Magic
	if magic == 0 {
		magic = MagicV0
	}
	out := make([]byte, HeaderSize+len(o.Payload))
	binary.BigEndian.PutUint16(out[0:2], magic)
	out[2] = version
	out[3] = o.Flags
	binary.BigEndian.PutUint64(out[4:12], o.SessionID)
	binary.BigEndian.PutUint64(out[12:20], o.Seq)
	binary.BigEndian.PutUint16(out[20:22], o.LinkID)
	binary.BigEndian.PutUint16(out[22:24], uint16(len(o.Payload)))
	if len(o.Payload) > 0 {
		copy(out[HeaderSize:], o.Payload)
	}
	return out, nil
}

// Decode parses bytes off the wire into a Frame. The returned Payload is a
// copy; the caller may recycle `bytes` immediately. Decode returns one of
// the package-level errors so callers can `errors.Is` against them when
// metricking.
func Decode(bytes []byte) (Frame, error) {
	if len(bytes) < HeaderSize {
		return Frame{}, fmt.Errorf("%w: %d < %d", ErrShortRead, len(bytes), HeaderSize)
	}
	magic := binary.BigEndian.Uint16(bytes[0:2])
	if magic != MagicV0 {
		return Frame{}, fmt.Errorf("%w: 0x%04x", ErrBadMagic, magic)
	}
	version := bytes[2]
	if version > ProtocolVersion {
		return Frame{}, fmt.Errorf("%w: %d", ErrUnsupportedVer, version)
	}
	flags := bytes[3]
	sessionID := binary.BigEndian.Uint64(bytes[4:12])
	seq := binary.BigEndian.Uint64(bytes[12:20])
	linkID := binary.BigEndian.Uint16(bytes[20:22])
	payloadLen := int(binary.BigEndian.Uint16(bytes[22:24]))
	if payloadLen > MaxPayload {
		return Frame{}, fmt.Errorf("%w: %d > %d", ErrPayloadTooLarge, payloadLen, MaxPayload)
	}
	if HeaderSize+payloadLen > len(bytes) {
		return Frame{}, fmt.Errorf("%w: want %d have %d",
			ErrTruncated, payloadLen, len(bytes)-HeaderSize)
	}
	payload := make([]byte, payloadLen)
	if payloadLen > 0 {
		copy(payload, bytes[HeaderSize:HeaderSize+payloadLen])
	}
	return Frame{
		Magic:     magic,
		Version:   version,
		Flags:     flags,
		SessionID: sessionID,
		Seq:       seq,
		LinkID:    linkID,
		Payload:   payload,
	}, nil
}
