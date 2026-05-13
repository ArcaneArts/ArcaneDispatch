// Wire format for the bonded transport (protocol v0).
//
// Mirror of `lib/bonded/bonded_framing.dart`. The two files MUST stay in
// lockstep — bump `kProtocolVersion` on BOTH sides when the frame layout
// changes in a breaking way. Cross-side compatibility is verified by the
// loopback tests in Dart and by the canned-bytes test in
// `test/bonded/bonded_framing_test.dart`.
//
// Frame layout (network byte order):
//   magic       u16   (0xDA01)
//   version     u8    (1)
//   flags       u8    bitfield (see BondedFlags)
//   sessionId   u64   per-tunnel
//   seq         u64   per-session monotonic
//   linkId      u16   per-session wire id (NOT the policy linkId string)
//   payloadLen  u16
//   payload     <= 1208 B application bytes
//
// Why 1208 B? Conservative IPv6 MTU floor of 1280 − 40 (IPv6 hdr) − 8
// (UDP hdr) = 1232, minus the 24-byte header. Above that we risk
// fragmentation on cell-tethered links.

import Foundation

/// Header magic — "Dispatch v0" first two bytes.
public let kBondedMagic: UInt16 = 0xDA01

/// Current protocol version. Decoders MUST refuse frames with a higher
/// version than they understand.
public let kBondedProtocolVersion: UInt8 = 1

/// Fixed header length in bytes.
public let kBondedHeaderSize: Int = 24

/// Max payload bytes per frame.
public let kBondedMaxPayload: Int = 1208

/// Flag bits in the header `flags` byte. Order MUST match
/// `bonded_framing.dart`.
public struct BondedFlags {
    public static let ack: UInt8 = 0x01
    public static let nak: UInt8 = 0x02
    public static let keepalive: UInt8 = 0x04
    public static let retransmit: UInt8 = 0x10
    public static let definedMask: UInt8 = 0x17
}

/// Decoded bonded frame. `payload` is a copy so the caller can keep it
/// around past the next decode without worrying about buffer reuse.
public struct BondedFrame {
    public let magic: UInt16
    public let version: UInt8
    public let flags: UInt8
    public let sessionId: UInt64
    public let seq: UInt64
    public let linkId: UInt16
    public let payload: Data

    public var isAck: Bool { (flags & BondedFlags.ack) != 0 }
    public var isNak: Bool { (flags & BondedFlags.nak) != 0 }
    public var isKeepalive: Bool { (flags & BondedFlags.keepalive) != 0 }
    public var isRetransmit: Bool { (flags & BondedFlags.retransmit) != 0 }
}

public enum BondedFramingError: Error, CustomStringConvertible {
    case shortRead(Int)
    case badMagic(UInt16)
    case unsupportedVersion(UInt8)
    case reservedFlagBits(UInt8)
    case payloadTooLarge(Int)
    case truncatedPayload(want: Int, have: Int)
    case linkIdOutOfRange(Int)

    public var description: String {
        switch self {
        case .shortRead(let n): return "short read: \(n) < \(kBondedHeaderSize)"
        case .badMagic(let m): return "bad magic: 0x\(String(m, radix: 16))"
        case .unsupportedVersion(let v): return "unsupported version: \(v)"
        case .reservedFlagBits(let f): return "reserved flag bits: 0x\(String(f, radix: 16))"
        case .payloadTooLarge(let n): return "payload too large: \(n) > \(kBondedMaxPayload)"
        case .truncatedPayload(let w, let h): return "truncated payload: want \(w), have \(h)"
        case .linkIdOutOfRange(let v): return "linkId out of range: \(v)"
        }
    }
}

/// Encode a bonded frame. Returns a freshly allocated `Data`; the caller
/// hands this to the UDP socket. No internal buffer pooling (we measured
/// the GC pressure on hot paths and it's acceptable for v0).
public func encodeBondedFrame(
    sessionId: UInt64,
    seq: UInt64,
    linkId: UInt16,
    flags: UInt8 = 0,
    payload: Data = Data(),
    version: UInt8 = kBondedProtocolVersion,
    magic: UInt16 = kBondedMagic
) throws -> Data {
    if payload.count > kBondedMaxPayload {
        throw BondedFramingError.payloadTooLarge(payload.count)
    }
    if (flags & ~BondedFlags.definedMask) != 0 {
        throw BondedFramingError.reservedFlagBits(flags)
    }
    var out = Data(count: kBondedHeaderSize + payload.count)
    out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        // big-endian writes via byte stores keep us free of unaligned
        // load surprises on the few ARM hosts that still care.
        let ptr = raw.baseAddress!
        // magic
        ptr.storeBytes(of: magic.bigEndian, as: UInt16.self)
        // version + flags
        ptr.advanced(by: 2).storeBytes(of: version, as: UInt8.self)
        ptr.advanced(by: 3).storeBytes(of: flags, as: UInt8.self)
        // sessionId
        ptr.advanced(by: 4).storeBytes(of: sessionId.bigEndian, as: UInt64.self)
        // seq
        ptr.advanced(by: 12).storeBytes(of: seq.bigEndian, as: UInt64.self)
        // linkId
        ptr.advanced(by: 20).storeBytes(of: linkId.bigEndian, as: UInt16.self)
        // payload length
        ptr.advanced(by: 22).storeBytes(
            of: UInt16(payload.count).bigEndian, as: UInt16.self)
    }
    if !payload.isEmpty {
        out.replaceSubrange(kBondedHeaderSize..<(kBondedHeaderSize + payload.count),
                            with: payload)
    }
    return out
}

/// Decode a bonded frame. Throws [`BondedFramingError`] on malformed input
/// so callers can silently drop stray packets; legitimate decode errors
/// don't propagate up to the user.
public func decodeBondedFrame(_ bytes: Data) throws -> BondedFrame {
    if bytes.count < kBondedHeaderSize {
        throw BondedFramingError.shortRead(bytes.count)
    }
    let magic: UInt16 = bytes.readUInt16BE(at: 0)
    if magic != kBondedMagic {
        throw BondedFramingError.badMagic(magic)
    }
    let version = bytes[bytes.startIndex + 2]
    if version > kBondedProtocolVersion {
        throw BondedFramingError.unsupportedVersion(version)
    }
    let flags = bytes[bytes.startIndex + 3]
    let sessionId = bytes.readUInt64BE(at: 4)
    let seq = bytes.readUInt64BE(at: 12)
    let linkId = bytes.readUInt16BE(at: 20)
    let payloadLen = Int(bytes.readUInt16BE(at: 22))
    if payloadLen > kBondedMaxPayload {
        throw BondedFramingError.payloadTooLarge(payloadLen)
    }
    if kBondedHeaderSize + payloadLen > bytes.count {
        throw BondedFramingError.truncatedPayload(
            want: payloadLen, have: bytes.count - kBondedHeaderSize)
    }
    let payload: Data
    if payloadLen == 0 {
        payload = Data()
    } else {
        let start = bytes.startIndex + kBondedHeaderSize
        payload = bytes.subdata(in: start..<(start + payloadLen))
    }
    return BondedFrame(
        magic: magic,
        version: version,
        flags: flags,
        sessionId: sessionId,
        seq: seq,
        linkId: linkId,
        payload: payload
    )
}

// MARK: - Data big-endian helpers

extension Data {
    /// Read a big-endian UInt16 at the given byte offset. Out-of-bounds
    /// returns 0 — the caller has already validated buffer length.
    func readUInt16BE(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        guard i + 2 <= endIndex else { return 0 }
        return (UInt16(self[i]) << 8) | UInt16(self[i + 1])
    }

    /// Read a big-endian UInt64 at the given byte offset.
    func readUInt64BE(at offset: Int) -> UInt64 {
        let i = startIndex + offset
        guard i + 8 <= endIndex else { return 0 }
        var v: UInt64 = 0
        for k in 0..<8 {
            v = (v << 8) | UInt64(self[i + k])
        }
        return v
    }
}
