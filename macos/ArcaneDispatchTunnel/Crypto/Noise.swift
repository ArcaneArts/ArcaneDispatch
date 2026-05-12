// Swift mirror of Noise_IK_25519_ChaChaPoly_SHA256 used by the
// dispatch bonded transport.
//
// This is the canonical macOS-side implementation. It must produce
// identical wire bytes to:
//   * `speed-server/crypto/noise.go` (Go)
//   * `lib/crypto/noise.dart` (Dart)
//
// See `test/crypto/noise_cross_test.dart` and
// `speed-server/crypto/noise_cross_test.go` for the locked vectors that
// keep all three in lockstep.
//
// Threading: a `HandshakeState` is single-owner. Post-split,
// `NoiseTransport` is also single-owner; we never share AEAD state
// across queues.

import CryptoKit
import Foundation

/// Protocol name mixed into the initial chaining hash. Changing this
/// string is a wire-breaking change.
public let noiseProtocolName = "Noise_IK_25519_ChaChaPoly_SHA256"

/// Max bytes permitted in any handshake payload.
public let noiseMaxHandshakePayload = 1024

/// Sides of the IK exchange.
public enum HandshakeRole { case initiator, responder }

/// X25519 keypair.
public struct NoiseKeypair {
    /// 32-byte raw scalar (what CryptoKit calls rawRepresentation).
    public let priv: Data
    /// 32-byte X25519 public point.
    public let pub: Data

    public init(priv: Data, pub: Data) {
        precondition(priv.count == 32, "priv must be 32 bytes")
        precondition(pub.count == 32, "pub must be 32 bytes")
        self.priv = priv
        self.pub = pub
    }

    /// Deterministic keypair from a 32-byte seed. The seed becomes the
    /// raw scalar; the public point is derived via X25519 base.
    public static func fromSeed(_ seed: Data) throws -> NoiseKeypair {
        guard seed.count == 32 else {
            throw NoiseError.invalidArgument("seed must be 32 bytes")
        }
        let key = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: seed
        )
        return NoiseKeypair(
            priv: Data(key.rawRepresentation),
            pub: Data(key.publicKey.rawRepresentation),
        )
    }

    /// Fresh random keypair.
    public static func generate() -> NoiseKeypair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return NoiseKeypair(
            priv: Data(key.rawRepresentation),
            pub: Data(key.publicKey.rawRepresentation),
        )
    }
}

/// Default rotation thresholds matching the Go/Dart sides. After
/// either threshold the session supervisor should schedule a fresh IK
/// handshake; the actual `NoiseTransport` itself does *not* refuse to
/// seal once these are exceeded.
public let noiseDefaultRotateBytes: UInt64 = 1 << 30      // 1 GiB
public let noiseDefaultRotateAgeSeconds: TimeInterval = 30 * 60  // 30 min

/// Post-handshake send/receive transport. Each direction owns its own
/// AEAD key and 64-bit nonce counter.
public final class NoiseTransport {
    public let sendKey: Data
    public let recvKey: Data
    private var sendNonce: UInt64 = 0

    /// Wall-clock timestamp when the transport was minted. The session
    /// supervisor pairs this with `sealedBytes` to schedule rotations
    /// at the same cadence as the Go and Dart mirrors.
    public let createdAt: Date

    /// Total plaintext bytes sealed since the transport was minted.
    public private(set) var sealedBytes: UInt64 = 0

    public init(sendKey: Data, recvKey: Data, createdAt: Date = Date()) {
        precondition(sendKey.count == 32, "sendKey must be 32 bytes")
        precondition(recvKey.count == 32, "recvKey must be 32 bytes")
        self.sendKey = sendKey
        self.recvKey = recvKey
        self.createdAt = createdAt
    }

    /// Returns `true` once either threshold is crossed; caller decides
    /// when to actually trigger the re-handshake.
    public func needsRotation(
        maxBytes: UInt64 = noiseDefaultRotateBytes,
        maxAge: TimeInterval = noiseDefaultRotateAgeSeconds,
    ) -> Bool {
        if sealedBytes >= maxBytes { return true }
        return Date().timeIntervalSince(createdAt) >= maxAge
    }

    /// AEAD-encrypts `plaintext` under the send key. Returns the nonce
    /// counter actually used plus the ciphertext+tag bytes.
    public func seal(
        ad: Data?, plaintext: Data
    ) throws -> (nonce: UInt64, ciphertext: Data) {
        if sendNonce == UInt64.max {
            throw NoiseError.state("crypto: send nonce exhausted (rekey required)")
        }
        let n = sendNonce
        let nonce = try ChaChaPoly.Nonce(data: noiseNonce12(n))
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: sendKey),
            nonce: nonce,
            authenticating: ad ?? Data(),
        )
        sendNonce += 1
        sealedBytes &+= UInt64(plaintext.count)
        var out = Data()
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return (nonce: n, ciphertext: out)
    }

    /// AEAD-decrypts a wire frame under the recv key. Caller is
    /// responsible for replay-window gatekeeping.
    public func open(nonce: UInt64, ad: Data?, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= 16 else {
            throw NoiseError.state("crypto: ciphertext too short for tag")
        }
        let tagStart = ciphertext.count - 16
        let body = ciphertext.prefix(tagStart)
        let tag = ciphertext.suffix(16)
        let aeadNonce = try ChaChaPoly.Nonce(data: noiseNonce12(nonce))
        let box = try ChaChaPoly.SealedBox(
            nonce: aeadNonce,
            ciphertext: body,
            tag: tag,
        )
        return try ChaChaPoly.open(
            box,
            using: SymmetricKey(data: recvKey),
            authenticating: ad ?? Data(),
        )
    }

    /// Diagnostic only: the next nonce a `seal()` would use.
    public var nextSendNonce: UInt64 { sendNonce }
}

/// Drives a single IK handshake (matches the Go and Dart side).
public final class HandshakeState {
    public let role: HandshakeRole
    private let s: NoiseKeypair
    private var e: NoiseKeypair? // local ephemeral (auto on init)
    private var rs: Data         // remote static
    private var hasRS: Bool
    private var re: Data = Data(count: 32)
    private var hasRE: Bool = false
    private var h: Data = Data(count: 32)
    private var ck: Data = Data(count: 32)
    private var k: Data = Data(count: 32)
    private var hasK: Bool = false
    private var n: UInt64 = 0

    private init(role: HandshakeRole, s: NoiseKeypair, rs: Data, hasRS: Bool) {
        self.role = role
        self.s = s
        self.rs = rs
        self.hasRS = hasRS
    }

    /// Build an initiator state. `rs` is the responder's static public key.
    public static func initiator(s: NoiseKeypair, rs: Data) throws -> HandshakeState {
        guard rs.count == 32 else {
            throw NoiseError.invalidArgument("responder static must be 32 bytes")
        }
        let hs = HandshakeState(role: .initiator, s: s, rs: rs, hasRS: true)
        hs.h = initialHash()
        hs.ck = hs.h
        hs.mixHash(rs)
        hs.e = NoiseKeypair.generate()
        return hs
    }

    /// Build a responder state. The initiator's static is learned during
    /// `readMessage1`.
    public static func responder(s: NoiseKeypair) -> HandshakeState {
        let hs = HandshakeState(role: .responder, s: s, rs: Data(count: 32), hasRS: false)
        hs.h = initialHash()
        hs.ck = hs.h
        hs.mixHash(s.pub)
        hs.e = NoiseKeypair.generate()
        return hs
    }

    /// TEST ONLY: replace the ephemeral with a deterministic seed.
    public func setTestEphemeral(seed: Data) throws {
        e = try NoiseKeypair.fromSeed(seed)
    }

    /// Build the first handshake message (initiator).
    public func writeMessage1(payload: Data) throws -> Data {
        guard role == .initiator else {
            throw NoiseError.state("writeMessage1 requires initiator")
        }
        guard payload.count <= noiseMaxHandshakePayload else {
            throw NoiseError.invalidArgument("handshake payload too large: \(payload.count)")
        }
        guard let e else {
            throw NoiseError.state("ephemeral missing")
        }
        var out = Data()
        // -- e --
        out.append(e.pub)
        mixHash(e.pub)
        // -- es --
        mixKey(try x25519(priv: e.priv, pub: rs))
        // -- s --
        out.append(try encryptAndHash(plaintext: s.pub))
        // -- ss --
        mixKey(try x25519(priv: s.priv, pub: rs))
        // -- payload --
        out.append(try encryptAndHash(plaintext: payload))
        return out
    }

    /// Parse the first handshake message (responder). Returns the
    /// decrypted application payload.
    public func readMessage1(_ msg: Data) throws -> Data {
        guard role == .responder else {
            throw NoiseError.state("readMessage1 requires responder")
        }
        guard msg.count >= 32 + 48 else {
            throw NoiseError.state("message1 too short: \(msg.count)")
        }
        re = Data(msg.prefix(32))
        hasRE = true
        mixHash(re)
        mixKey(try x25519(priv: s.priv, pub: re))
        let encS = Data(msg.subdata(in: 32..<(32 + 48)))
        let peerStatic = try decryptAndHash(ciphertext: encS)
        guard peerStatic.count == 32 else {
            throw NoiseError.state("bad initiator static len: \(peerStatic.count)")
        }
        rs = peerStatic
        hasRS = true
        mixKey(try x25519(priv: s.priv, pub: rs))
        let encPayload = Data(msg.subdata(in: (32 + 48)..<msg.count))
        return try decryptAndHash(ciphertext: encPayload)
    }

    /// Build the second handshake message (responder). Returns the wire
    /// bytes plus the post-handshake transport.
    public func writeMessage2(payload: Data) throws -> (msg: Data, transport: NoiseTransport) {
        guard role == .responder else {
            throw NoiseError.state("writeMessage2 requires responder")
        }
        guard hasRE, hasRS else {
            throw NoiseError.state("responder missing peer keys (no readMessage1?)")
        }
        guard payload.count <= noiseMaxHandshakePayload else {
            throw NoiseError.invalidArgument("handshake payload too large: \(payload.count)")
        }
        guard let e else {
            throw NoiseError.state("ephemeral missing")
        }
        var out = Data()
        out.append(e.pub)
        mixHash(e.pub)
        mixKey(try x25519(priv: e.priv, pub: re))
        mixKey(try x25519(priv: e.priv, pub: rs))
        out.append(try encryptAndHash(plaintext: payload))
        return (msg: out, transport: split())
    }

    /// Parse the second handshake message (initiator). Returns the
    /// decrypted payload plus the post-handshake transport.
    public func readMessage2(_ msg: Data) throws -> (payload: Data, transport: NoiseTransport) {
        guard role == .initiator else {
            throw NoiseError.state("readMessage2 requires initiator")
        }
        guard msg.count >= 32 else {
            throw NoiseError.state("message2 too short: \(msg.count)")
        }
        guard let e else {
            throw NoiseError.state("ephemeral missing")
        }
        re = Data(msg.prefix(32))
        hasRE = true
        mixHash(re)
        mixKey(try x25519(priv: e.priv, pub: re))
        mixKey(try x25519(priv: s.priv, pub: re))
        let encPayload = Data(msg.subdata(in: 32..<msg.count))
        let payload = try decryptAndHash(ciphertext: encPayload)
        return (payload: payload, transport: split())
    }

    /// Peer's static public key. Meaningful on the responder after
    /// `readMessage1`.
    public var remoteStatic: Data { rs }

    // ----- Internals -----

    private func mixHash(_ data: Data) {
        var buf = Data()
        buf.append(h)
        buf.append(data)
        h = Data(SHA256.hash(data: buf))
    }

    private func mixKey(_ input: Data) {
        let (out1, out2) = hkdf2(chainingKey: ck, ikm: input)
        ck = out1
        k = out2
        hasK = true
        n = 0
    }

    private func encryptAndHash(plaintext: Data) throws -> Data {
        if !hasK {
            mixHash(plaintext)
            return plaintext
        }
        let nonce = try ChaChaPoly.Nonce(data: noiseNonce12(n))
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: k),
            nonce: nonce,
            authenticating: h,
        )
        var ct = Data()
        ct.append(sealed.ciphertext)
        ct.append(sealed.tag)
        n += 1
        mixHash(ct)
        return ct
    }

    private func decryptAndHash(ciphertext: Data) throws -> Data {
        if !hasK {
            mixHash(ciphertext)
            return ciphertext
        }
        guard ciphertext.count >= 16 else {
            throw NoiseError.state("ciphertext too short for tag")
        }
        let tagStart = ciphertext.count - 16
        let body = ciphertext.prefix(tagStart)
        let tag = ciphertext.suffix(16)
        let aeadNonce = try ChaChaPoly.Nonce(data: noiseNonce12(n))
        let box = try ChaChaPoly.SealedBox(
            nonce: aeadNonce,
            ciphertext: body,
            tag: tag,
        )
        let plain = try ChaChaPoly.open(
            box,
            using: SymmetricKey(data: k),
            authenticating: h,
        )
        n += 1
        mixHash(ciphertext)
        return plain
    }

    private func split() -> NoiseTransport {
        let (out1, out2) = hkdf2(chainingKey: ck, ikm: Data())
        if role == .responder {
            return NoiseTransport(sendKey: out2, recvKey: out1)
        }
        return NoiseTransport(sendKey: out1, recvKey: out2)
    }
}

// ----- Primitives shared with the Go/Dart sides -----

/// 12-byte ChaCha20-Poly1305 nonce: 4 zero bytes + little-endian u64.
public func noiseNonce12(_ counter: UInt64) -> Data {
    var out = Data(count: 12)
    var le = counter.littleEndian
    withUnsafeBytes(of: &le) { src in
        out.replaceSubrange(4..<12, with: src)
    }
    return out
}

/// Initial chaining hash: pad/hash the protocol name to 32 bytes.
private func initialHash() -> Data {
    let pn = Data(noiseProtocolName.utf8)
    if pn.count <= 32 {
        var h = Data(count: 32)
        h.replaceSubrange(0..<pn.count, with: pn)
        return h
    }
    return Data(SHA256.hash(data: pn))
}

/// HKDF-SHA256 emitting two 32-byte outputs (Noise's `HKDF2`).
public func hkdf2(chainingKey: Data, ikm: Data) -> (Data, Data) {
    let temp = hmacSha256(key: chainingKey, data: ikm)
    let out1 = hmacSha256(key: temp, data: Data([0x01]))
    var out2Input = Data()
    out2Input.append(out1)
    out2Input.append(0x02)
    let out2 = hmacSha256(key: temp, data: out2Input)
    return (out1, out2)
}

/// HMAC-SHA-256 via CryptoKit.
public func hmacSha256(key: Data, data: Data) -> Data {
    let k = SymmetricKey(data: key)
    let mac = HMAC<SHA256>.authenticationCode(for: data, using: k)
    return Data(mac)
}

/// X25519 shared secret. Rejects all-zero output per Noise spec.
public func x25519(priv: Data, pub: Data) throws -> Data {
    let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv)
    let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)
    let shared = try key.sharedSecretFromKeyAgreement(with: peer)
    let bytes = shared.withUnsafeBytes { Data($0) }
    if bytes.allSatisfy({ $0 == 0 }) {
        throw NoiseError.state("crypto: X25519 output is all-zero")
    }
    return bytes
}

/// Public convenience used by the seal layer.
public func sha256Sync(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
}

public enum NoiseError: Error, CustomStringConvertible {
    case invalidArgument(String)
    case state(String)

    public var description: String {
        switch self {
        case .invalidArgument(let m): return "noise: invalid argument: \(m)"
        case .state(let m): return "noise: \(m)"
        }
    }
}
