// Swift mirror of the sealed-frame wrapper used by the bonded transport.
//
// See `speed-server/crypto/seal.go` and `lib/crypto/seal.dart` for the
// canonical prose. The wire format is fixed at:
//
//   offset  size  field
//   0       2     magic   (big-endian u16, always 0xDA02)
//   2       1     version (always 0x01)
//   3       1     flags   (must be 0; reserved)
//   4       8     nonce   (big-endian u64, AEAD nonce counter)
//   12      ...   ciphertext+tag

import Foundation

/// First two bytes of every sealed frame.
public let sealedMagic: UInt16 = 0xDA02
public let sealedVersion: UInt8 = 1
public let sealedHeaderSize: Int = 12

public struct SealedHeader {
    public let magic: UInt16
    public let version: UInt8
    public let flags: UInt8
    public let nonce: UInt64
}

/// Wraps `plaintext` under `transport`'s send key and returns the wire
/// bytes (header || ciphertext+tag). The header bytes are mixed into the
/// AEAD additional-data so any header tampering fails the AEAD tag.
public func seal(transport: NoiseTransport, plaintext: Data) throws -> Data {
    let predicted = transport.nextSendNonce
    let hdr = sealedHeaderBytes(nonce: predicted, flags: 0)
    let sealed = try transport.seal(ad: hdr, plaintext: plaintext)
    guard sealed.nonce == predicted else {
        throw NoiseError.state(
            "crypto: seal nonce drift (predicted \(predicted), got \(sealed.nonce))"
        )
    }
    var out = Data()
    out.append(hdr)
    out.append(sealed.ciphertext)
    return out
}

/// Parse just the header from `buf`. Throws on short input, bad magic,
/// bad version, or reserved flags.
public func decodeSealedHeader(_ buf: Data) throws -> SealedHeader {
    guard buf.count >= sealedHeaderSize else {
        throw NoiseError.state(
            "crypto: sealed frame too short: \(buf.count) < \(sealedHeaderSize)"
        )
    }
    let magic =
        UInt16(buf[buf.startIndex]) << 8 |
        UInt16(buf[buf.index(buf.startIndex, offsetBy: 1)])
    guard magic == sealedMagic else {
        throw NoiseError.state(
            "crypto: bad sealed magic: 0x\(String(magic, radix: 16))"
        )
    }
    let version = buf[buf.index(buf.startIndex, offsetBy: 2)]
    guard version == sealedVersion else {
        throw NoiseError.state("crypto: unsupported sealed version: \(version)")
    }
    let flags = buf[buf.index(buf.startIndex, offsetBy: 3)]
    guard flags == 0 else {
        throw NoiseError.state(
            "crypto: reserved sealed flag bits set: 0x\(String(flags, radix: 16))"
        )
    }
    var nonce: UInt64 = 0
    for i in 0..<8 {
        nonce =
            (nonce << 8) |
            UInt64(buf[buf.index(buf.startIndex, offsetBy: 4 + i)])
    }
    return SealedHeader(
        magic: magic, version: version, flags: flags, nonce: nonce,
    )
}

/// AEAD-decrypts a wire-format sealed frame. Caller still owns the
/// replay window — `openSealed` only enforces the tag.
public func openSealed(
    transport: NoiseTransport,
    header: SealedHeader,
    ciphertext: Data
) throws -> Data {
    let ad = sealedHeaderBytes(nonce: header.nonce, flags: header.flags)
    return try transport.open(
        nonce: header.nonce, ad: ad, ciphertext: ciphertext
    )
}

private func sealedHeaderBytes(nonce: UInt64, flags: UInt8) -> Data {
    var hdr = Data(count: sealedHeaderSize)
    hdr[0] = UInt8((sealedMagic >> 8) & 0xFF)
    hdr[1] = UInt8(sealedMagic & 0xFF)
    hdr[2] = sealedVersion
    hdr[3] = flags
    for i in 0..<8 {
        hdr[4 + i] = UInt8((nonce >> ((7 - i) * 8)) & 0xFF)
    }
    return hdr
}
