// Wire format for the bonded transport (protocol v0).
//
// Mirrored on the Swift side by
// `macos/ArcaneDispatchTunnel/Bonded/BondedFraming.swift`. Both files MUST be
// updated in lock-step — bump `kProtocolVersion` on both sides whenever the
// frame layout changes in a breaking way.
//
// Frame layout (all big-endian / network byte order):
//
//   ┌─────────── header (24 B) ───────────┐
//   │ magic       2  u16   (0xDA01)       │
//   │ version     1  u8    (1)            │
//   │ flags       1  u8    bitfield       │
//   │ sessionId   8  u64                  │
//   │ seq         8  u64   per-session    │
//   │ linkId      2  u16   per-session    │
//   │ payloadLen  2  u16                  │
//   └─────────────────────────────────────┘
//   ┌────────── payload (≤ 1232 B) ───────┐
//   │ application bytes                   │
//   └─────────────────────────────────────┘
//
// Why 1232 B max? Conservative MTU floor: 1280 (IPv6) − 40 (IPv6 hdr) − 8
// (UDP hdr) = 1232. Above that we'd risk fragmentation on the cellular links
// where MTU is often clamped. Header is 24 B → max payload chunk is 1232 −
// 24 = 1208 B per UDP datagram. The scheduler chunks larger writes.
//
// Flags bitfield (LSB first):
//   bit 0      — ack    (the packet is an ACK; payload may carry a NAK range)
//   bit 1      — nak    (NAK piggyback in payload)
//   bit 2      — kalive (keepalive; payload = u64 inflight counter)
//   bit 4      — rtx    (retransmission)
//   bits 3,5-7 — reserved (MUST be zero on encode, ignored on decode)

import 'dart:typed_data';

/// Header magic — "Dispatch v0" first two bytes. Anything else on the wire is
/// either junk, a probe from an unrelated protocol, or a corrupted packet
/// and MUST be dropped.
const int kBondedMagic = 0xDA01;

/// Current protocol version. Decoders MUST refuse frames with a higher
/// version than they understand and surface a sessionFailed event so the
/// client can downgrade.
const int kBondedProtocolVersion = 1;

/// Fixed header length in bytes.
const int kBondedHeaderSize = 24;

/// Max payload bytes per frame. Anything larger must be split by the caller.
/// 1232 (IPv6 conservative floor) − 24 (header) = 1208.
const int kBondedMaxPayload = 1208;

/// Bitfield for the `flags` byte. Order MUST match `BondedFraming.swift`.
class BondedFlags {
  /// Frame carries an ACK; payload may piggyback NAK ranges.
  static const int ack = 0x01;

  /// Frame carries a NAK (gap report from the reassembler).
  static const int nak = 0x02;

  /// Keepalive frame; payload is the sender's `inflight` counter (u64 LE).
  static const int keepalive = 0x04;

  /// This frame is a retransmission of a previously-sent seq.
  static const int retransmit = 0x10;

  /// Mask of all defined bits. Used to assert reserved bits are zero on
  /// encode and to mask unknowns on decode.
  static const int definedMask = 0x17;
}

/// Decoded bonded frame.
///
/// All integers are unsigned wire values; Dart `int` is plenty wide for u64.
/// Payload is a view into the source buffer when possible — the caller is
/// responsible for copying if it needs to retain the bytes past the next
/// decode.
class BondedFrame {
  final int magic;
  final int version;
  final int flags;
  final int sessionId;
  final int seq;
  final int linkId;
  final Uint8List payload;

  const BondedFrame({
    required this.magic,
    required this.version,
    required this.flags,
    required this.sessionId,
    required this.seq,
    required this.linkId,
    required this.payload,
  });

  bool get isAck => (flags & BondedFlags.ack) != 0;
  bool get isNak => (flags & BondedFlags.nak) != 0;
  bool get isKeepalive => (flags & BondedFlags.keepalive) != 0;
  bool get isRetransmit => (flags & BondedFlags.retransmit) != 0;

  @override
  String toString() {
    return 'BondedFrame(session=$sessionId, seq=$seq, link=$linkId, '
        'flags=0x${flags.toRadixString(16)}, payload=${payload.length}B)';
  }
}

/// Thrown when [decodeBondedFrame] is fed bytes that don't look like a bonded
/// frame. Distinct exception so callers can distinguish "wrong magic" /
/// "wrong version" (probably a stray packet) from real network errors and
/// silently drop the packet.
class BondedFramingException implements Exception {
  final String message;
  BondedFramingException(this.message);

  @override
  String toString() => 'BondedFramingException: $message';
}

/// Encode a frame into a fresh `Uint8List`. Caller is expected to feed this
/// into a UDP socket's `send` (no in-place reuse since we don't pool here —
/// the GC handles allocations well below 100k frames/s in practice).
///
/// Throws [BondedFramingException] when:
/// * `payload.length > kBondedMaxPayload`
/// * `flags` carries reserved bits (caller is buggy)
/// * any unsigned field overflows its on-wire width (caller is buggy)
Uint8List encodeBondedFrame({
  required int sessionId,
  required int seq,
  required int linkId,
  int flags = 0,
  Uint8List? payload,
  int version = kBondedProtocolVersion,
  int magic = kBondedMagic,
}) {
  Uint8List body = payload ?? Uint8List(0);
  if (body.length > kBondedMaxPayload) {
    throw BondedFramingException(
      'payload too large (${body.length} > $kBondedMaxPayload)',
    );
  }
  if ((flags & ~BondedFlags.definedMask) != 0) {
    throw BondedFramingException(
      'reserved flag bits set: 0x${flags.toRadixString(16)}',
    );
  }
  if (linkId < 0 || linkId > 0xffff) {
    throw BondedFramingException('linkId out of range: $linkId');
  }
  if (version < 0 || version > 0xff) {
    throw BondedFramingException('version out of range: $version');
  }
  if (magic < 0 || magic > 0xffff) {
    throw BondedFramingException('magic out of range');
  }
  // sessionId and seq are wire-level u64. Dart `int` is signed, so a
  // u64 literal with the high bit set (e.g. 0xABCD000000000001) looks
  // negative — we don't reject it. `setUint64` writes the raw bit
  // pattern, which is exactly what an unsigned wire field should carry.

  Uint8List out = Uint8List(kBondedHeaderSize + body.length);
  ByteData bd = ByteData.sublistView(out);
  bd.setUint16(0, magic, Endian.big);
  out[2] = version & 0xff;
  out[3] = flags & 0xff;
  bd.setUint64(4, sessionId, Endian.big);
  bd.setUint64(12, seq, Endian.big);
  bd.setUint16(20, linkId & 0xffff, Endian.big);
  bd.setUint16(22, body.length & 0xffff, Endian.big);
  if (body.isNotEmpty) {
    out.setRange(kBondedHeaderSize, kBondedHeaderSize + body.length, body);
  }
  return out;
}

/// Decode a bonded frame. Throws [BondedFramingException] for unrecoverable
/// errors (wrong magic, truncation, oversize payload, bad version). On
/// success the returned frame's `payload` is a *view* into [bytes] — copy
/// before reusing the source buffer if you need ownership.
BondedFrame decodeBondedFrame(Uint8List bytes) {
  if (bytes.length < kBondedHeaderSize) {
    throw BondedFramingException(
      'short read: ${bytes.length} < $kBondedHeaderSize',
    );
  }
  ByteData bd = ByteData.sublistView(bytes);
  int magic = bd.getUint16(0, Endian.big);
  if (magic != kBondedMagic) {
    throw BondedFramingException(
      'bad magic: 0x${magic.toRadixString(16)} (want 0xDA01)',
    );
  }
  int version = bytes[2];
  if (version > kBondedProtocolVersion) {
    throw BondedFramingException(
      'unsupported version: $version (max $kBondedProtocolVersion)',
    );
  }
  int flags = bytes[3];
  // Mask reserved bits down so callers always see a well-formed bitfield,
  // but the wire-level set is what we encoded — we don't tamper with the
  // input buffer.
  flags &= 0xff;
  int sessionId = bd.getUint64(4, Endian.big);
  int seq = bd.getUint64(12, Endian.big);
  int linkId = bd.getUint16(20, Endian.big);
  int payloadLen = bd.getUint16(22, Endian.big);
  if (payloadLen > kBondedMaxPayload) {
    throw BondedFramingException(
      'payload too large: $payloadLen > $kBondedMaxPayload',
    );
  }
  if (kBondedHeaderSize + payloadLen > bytes.length) {
    throw BondedFramingException(
      'truncated payload: want $payloadLen, have ${bytes.length - kBondedHeaderSize}',
    );
  }
  // Slice (zero-copy view) over the payload. If the caller wants ownership
  // they call `Uint8List.fromList(frame.payload)` themselves.
  Uint8List payload = payloadLen == 0
      ? Uint8List(0)
      : Uint8List.sublistView(
          bytes,
          kBondedHeaderSize,
          kBondedHeaderSize + payloadLen,
        );
  return BondedFrame(
    magic: magic,
    version: version,
    flags: flags,
    sessionId: sessionId,
    seq: seq,
    linkId: linkId,
    payload: payload,
  );
}
