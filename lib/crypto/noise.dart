/// Dart mirror of the Noise_IK_25519_ChaChaPoly_SHA256 handshake.
///
/// See `speed-server/crypto/noise.go` for the prose; this file is a
/// literal port. We share canned-bytes test vectors in
/// `test/crypto/noise_cross_test.dart` with the Go side, so any drift
/// surfaces in CI.
///
/// Threading: each `HandshakeState` is single-owner. The hot path
/// allocates a few `Uint8List`s per message — fine for handshake
/// frequency (once per session). The `Transport` returned by `split()`
/// is also single-owner; we never share AEAD state across isolates.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The exact ASCII protocol name mixed into the initial chaining hash.
/// Changing this string breaks cross-language compatibility.
const String protocolName = 'Noise_IK_25519_ChaChaPoly_SHA256';

/// Max bytes permitted in a handshake payload. Mirrors the Go side.
const int maxHandshakePayload = 1024;

/// Which side of the IK exchange we're driving.
enum HandshakeRole { initiator, responder }

/// X25519 keypair. Mirrors `speed-server/crypto/noise.go::Keypair`.
class NoiseKeypair {
  final Uint8List private;
  final Uint8List public;

  NoiseKeypair({required this.private, required this.public});

  /// Deterministic keypair from a 32-byte seed. The seed is the raw
  /// scalar; the public key is derived via curve25519's base-point
  /// multiplication.
  static Future<NoiseKeypair> fromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError('seed must be 32 bytes');
    }
    X25519 algo = X25519();
    SimpleKeyPair pair = await algo.newKeyPairFromSeed(seed);
    SimpleKeyPairData data = await pair.extract();
    SimplePublicKey pub = await pair.extractPublicKey();
    return NoiseKeypair(
      private: Uint8List.fromList(data.bytes),
      public: Uint8List.fromList(pub.bytes),
    );
  }

  /// Fresh random keypair from the platform RNG.
  static Future<NoiseKeypair> generate() async {
    X25519 algo = X25519();
    SimpleKeyPair pair = await algo.newKeyPair();
    SimpleKeyPairData data = await pair.extract();
    SimplePublicKey pub = await pair.extractPublicKey();
    return NoiseKeypair(
      private: Uint8List.fromList(data.bytes),
      public: Uint8List.fromList(pub.bytes),
    );
  }
}

/// Post-handshake send/receive context. Each direction has its own AEAD
/// key + nonce counter. Mirrors Go `crypto.Transport`.
class NoiseTransport {
  final Uint8List sendKey;
  final Uint8List recvKey;
  int _sendNonce = 0;

  /// Wall-clock timestamp when the transport was minted. The session
  /// supervisor uses this together with [sealedBytes] to decide when to
  /// trigger a re-handshake (rotation). Mirror of the Go and Swift
  /// counters so all three sides agree on the cadence.
  final DateTime createdAt;

  /// Total plaintext bytes sealed so far (does not include the AEAD tag
  /// or the wire header). 64-bit so a 100 Gbit/s link can run for ~46
  /// days before overflow.
  int _sealedBytes = 0;

  NoiseTransport({required this.sendKey, required this.recvKey, DateTime? createdAt})
      : createdAt = createdAt ?? DateTime.now();

  /// Total plaintext bytes sealed since the transport was minted.
  int get sealedBytes => _sealedBytes;

  /// Returns `true` once the transport has crossed *either* the byte cap
  /// or the wall-clock age cap and should be replaced by a fresh
  /// handshake. The caller decides what "replace" means (typically the
  /// session supervisor schedules a Noise re-handshake on the next
  /// quiescent moment).
  ///
  /// Defaults mirror the master plan: 1 GiB or 30 minutes.
  bool needsRotation({
    int maxBytes = _defaultRotateBytes,
    Duration maxAge = _defaultRotateAge,
  }) {
    if (_sealedBytes >= maxBytes) return true;
    return DateTime.now().difference(createdAt) >= maxAge;
  }

  /// AEAD-encrypts [plaintext] under the send key. Returns the nonce
  /// counter actually used plus the ciphertext+tag bytes.
  Future<({int nonce, Uint8List ciphertext})> seal(
    Uint8List? ad,
    Uint8List plaintext,
  ) async {
    if (_sendNonce == _maxU64) {
      throw StateError('crypto: send nonce exhausted (rekey required)');
    }
    int n = _sendNonce;
    SecretBox box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(sendKey),
      nonce: _nonce12(n),
      aad: ad ?? Uint8List(0),
    );
    _sendNonce++;
    _sealedBytes += plaintext.length;
    // The `cryptography` package returns SecretBox = (nonce, cipher, mac).
    // Our wire format puts the MAC after the ciphertext, so we
    // concatenate cipher||mac to match Go's `chacha20poly1305.Seal` shape.
    Uint8List wire = Uint8List(box.cipherText.length + box.mac.bytes.length);
    wire.setRange(0, box.cipherText.length, box.cipherText);
    wire.setRange(box.cipherText.length, wire.length, box.mac.bytes);
    return (nonce: n, ciphertext: wire);
  }

  /// AEAD-decrypts a wire frame under the recv key. Caller is responsible
  /// for replay-window gatekeeping — `open()` only enforces the AEAD tag.
  Future<Uint8List> open(int nonce, Uint8List? ad, Uint8List ciphertext) async {
    if (ciphertext.length < 16) {
      throw StateError('crypto: ciphertext too short for tag');
    }
    int macStart = ciphertext.length - 16;
    Uint8List body = Uint8List.sublistView(ciphertext, 0, macStart);
    Uint8List mac = Uint8List.sublistView(ciphertext, macStart);
    SecretBox box = SecretBox(
      body,
      nonce: _nonce12(nonce),
      mac: Mac(mac),
    );
    List<int> plain = await _aead.decrypt(
      box,
      secretKey: SecretKey(recvKey),
      aad: ad ?? Uint8List(0),
    );
    return Uint8List.fromList(plain);
  }

  /// Next nonce that `seal()` would consume. Diagnostic only.
  int get sendNonce => _sendNonce;
}

const int _maxU64 = 0xFFFFFFFFFFFFFFFF;
final Chacha20 _aead = Chacha20.poly1305Aead();

/// Default rotation thresholds; matches the spec in the master plan and
/// the Go/Swift mirrors.
const int _defaultRotateBytes = 1 << 30; // 1 GiB sealed bytes
const Duration _defaultRotateAge = Duration(minutes: 30);

/// Drives a single IK handshake. Mirrors Go `HandshakeState`.
class HandshakeState {
  final HandshakeRole role;
  final NoiseKeypair s;
  NoiseKeypair? _e; // local ephemeral; auto-generated lazily
  Uint8List _rs; // remote static (known up-front on initiator)
  bool _hasRS = false;
  Uint8List _re = Uint8List(32);
  bool _hasRE = false;
  Uint8List _h = Uint8List(32);
  Uint8List _ck = Uint8List(32);
  Uint8List _k = Uint8List(32);
  bool _hasK = false;
  int _n = 0;

  HandshakeState._({
    required this.role,
    required this.s,
    required Uint8List rs,
    required bool hasRS,
  }) : _rs = rs {
    _hasRS = hasRS;
  }

  /// Build an initiator-side handshake. `rs` is the responder's known
  /// static public key (32 bytes).
  static Future<HandshakeState> initiator({
    required NoiseKeypair s,
    required Uint8List rs,
  }) async {
    if (rs.length != 32) {
      throw ArgumentError('responder static must be 32 bytes');
    }
    HandshakeState hs = HandshakeState._(
      role: HandshakeRole.initiator,
      s: s,
      rs: Uint8List.fromList(rs),
      hasRS: true,
    );
    hs._h = _initialHash();
    hs._ck = Uint8List.fromList(hs._h);
    hs._mixHash(rs);
    hs._e = await NoiseKeypair.generate();
    return hs;
  }

  /// Build a responder-side handshake. The responder learns the
  /// initiator's static during `readMessage1()`.
  static Future<HandshakeState> responder({required NoiseKeypair s}) async {
    HandshakeState hs = HandshakeState._(
      role: HandshakeRole.responder,
      s: s,
      rs: Uint8List(32),
      hasRS: false,
    );
    hs._h = _initialHash();
    hs._ck = Uint8List.fromList(hs._h);
    hs._mixHash(s.public);
    hs._e = await NoiseKeypair.generate();
    return hs;
  }

  /// TEST ONLY: override the auto-generated ephemeral with a fixed seed.
  /// Lets cross-language vectors stay deterministic.
  Future<void> setTestEphemeral(Uint8List seed) async {
    _e = await NoiseKeypair.fromSeed(seed);
  }

  /// Build the first handshake message (initiator only).
  Future<Uint8List> writeMessage1(Uint8List payload) async {
    if (role != HandshakeRole.initiator) {
      throw StateError('writeMessage1 requires initiator');
    }
    if (payload.length > maxHandshakePayload) {
      throw ArgumentError('handshake payload too large: ${payload.length}');
    }
    NoiseKeypair e = _e!;
    BytesBuilder out = BytesBuilder();
    // -- e --
    out.add(e.public);
    _mixHash(e.public);
    // -- es --
    Uint8List dh1 = await _x25519(e.private, _rs);
    _mixKey(dh1);
    // -- s --
    Uint8List encS = await _encryptAndHash(s.public);
    out.add(encS);
    // -- ss --
    Uint8List dh2 = await _x25519(s.private, _rs);
    _mixKey(dh2);
    // -- payload --
    Uint8List encPayload = await _encryptAndHash(payload);
    out.add(encPayload);
    return out.toBytes();
  }

  /// Parse the first handshake message (responder only). Returns the
  /// decrypted application payload.
  Future<Uint8List> readMessage1(Uint8List msg) async {
    if (role != HandshakeRole.responder) {
      throw StateError('readMessage1 requires responder');
    }
    if (msg.length < 32 + 48) {
      throw StateError('message1 too short: ${msg.length}');
    }
    // -- e --
    _re = Uint8List.fromList(msg.sublist(0, 32));
    _hasRE = true;
    _mixHash(_re);
    // -- es --
    Uint8List dh1 = await _x25519(s.private, _re);
    _mixKey(dh1);
    // -- s --
    Uint8List encS = Uint8List.sublistView(msg, 32, 32 + 48);
    Uint8List rs = await _decryptAndHash(encS);
    if (rs.length != 32) {
      throw StateError('bad initiator static len: ${rs.length}');
    }
    _rs = rs;
    _hasRS = true;
    // -- ss --
    Uint8List dh2 = await _x25519(s.private, _rs);
    _mixKey(dh2);
    // -- payload --
    Uint8List encPayload = Uint8List.sublistView(msg, 32 + 48);
    return await _decryptAndHash(encPayload);
  }

  /// Build the second handshake message (responder only). Returns the
  /// wire bytes plus the post-handshake [NoiseTransport].
  Future<({Uint8List msg, NoiseTransport transport})> writeMessage2(
    Uint8List payload,
  ) async {
    if (role != HandshakeRole.responder) {
      throw StateError('writeMessage2 requires responder');
    }
    if (!_hasRE || !_hasRS) {
      throw StateError('responder missing peer keys (no readMessage1?)');
    }
    if (payload.length > maxHandshakePayload) {
      throw ArgumentError('handshake payload too large: ${payload.length}');
    }
    NoiseKeypair e = _e!;
    BytesBuilder out = BytesBuilder();
    // -- e --
    out.add(e.public);
    _mixHash(e.public);
    // -- ee --
    Uint8List dh1 = await _x25519(e.private, _re);
    _mixKey(dh1);
    // -- se --
    Uint8List dh2 = await _x25519(e.private, _rs);
    _mixKey(dh2);
    // -- payload --
    Uint8List encPayload = await _encryptAndHash(payload);
    out.add(encPayload);
    NoiseTransport t = _split();
    return (msg: out.toBytes(), transport: t);
  }

  /// Parse the second handshake message (initiator only). Returns the
  /// decrypted application payload plus the post-handshake transport.
  Future<({Uint8List payload, NoiseTransport transport})> readMessage2(
    Uint8List msg,
  ) async {
    if (role != HandshakeRole.initiator) {
      throw StateError('readMessage2 requires initiator');
    }
    if (msg.length < 32) {
      throw StateError('message2 too short: ${msg.length}');
    }
    NoiseKeypair e = _e!;
    // -- e --
    _re = Uint8List.fromList(msg.sublist(0, 32));
    _hasRE = true;
    _mixHash(_re);
    // -- ee --
    Uint8List dh1 = await _x25519(e.private, _re);
    _mixKey(dh1);
    // -- se --
    Uint8List dh2 = await _x25519(s.private, _re);
    _mixKey(dh2);
    // -- payload --
    Uint8List encPayload = Uint8List.sublistView(msg, 32);
    Uint8List plain = await _decryptAndHash(encPayload);
    NoiseTransport t = _split();
    return (payload: plain, transport: t);
  }

  /// Peer's static public key. Meaningful on the responder after
  /// `readMessage1`.
  Uint8List get remoteStatic => _rs;

  // ----- Internal helpers -----

  void _mixHash(Uint8List data) {
    BytesBuilder bb = BytesBuilder();
    bb.add(_h);
    bb.add(data);
    _h = _sha256Sync(bb.toBytes());
  }

  void _mixKey(Uint8List input) {
    (Uint8List, Uint8List) outputs = _hkdf2(_ck, input);
    _ck = outputs.$1;
    _k = outputs.$2;
    _hasK = true;
    _n = 0;
  }

  Future<Uint8List> _encryptAndHash(Uint8List plaintext) async {
    if (!_hasK) {
      _mixHash(plaintext);
      return plaintext;
    }
    SecretBox box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(_k),
      nonce: _nonce12(_n),
      aad: _h,
    );
    Uint8List ct = Uint8List(box.cipherText.length + box.mac.bytes.length);
    ct.setRange(0, box.cipherText.length, box.cipherText);
    ct.setRange(box.cipherText.length, ct.length, box.mac.bytes);
    _n++;
    _mixHash(ct);
    return ct;
  }

  Future<Uint8List> _decryptAndHash(Uint8List ciphertext) async {
    if (!_hasK) {
      _mixHash(ciphertext);
      return ciphertext;
    }
    if (ciphertext.length < 16) {
      throw StateError('ciphertext too short for tag');
    }
    int macStart = ciphertext.length - 16;
    SecretBox box = SecretBox(
      Uint8List.sublistView(ciphertext, 0, macStart),
      nonce: _nonce12(_n),
      mac: Mac(Uint8List.sublistView(ciphertext, macStart)),
    );
    List<int> plain = await _aead.decrypt(
      box,
      secretKey: SecretKey(_k),
      aad: _h,
    );
    _n++;
    _mixHash(ciphertext);
    return Uint8List.fromList(plain);
  }

  NoiseTransport _split() {
    (Uint8List, Uint8List) outputs = _hkdf2(_ck, Uint8List(0));
    Uint8List sendKey;
    Uint8List recvKey;
    if (role == HandshakeRole.responder) {
      sendKey = outputs.$2;
      recvKey = outputs.$1;
    } else {
      sendKey = outputs.$1;
      recvKey = outputs.$2;
    }
    return NoiseTransport(sendKey: sendKey, recvKey: recvKey);
  }

  /// Snapshot of the current transcript hash. Identical on both peers
  /// after the handshake completes when no tampering occurred. Used by
  /// Pair & Share to derive a short numeric verification code that the
  /// user reads off both screens.
  Uint8List transcriptHash() => Uint8List.fromList(_h);
}

// ----- Shared primitives -----

Uint8List _initialHash() {
  Uint8List pn = Uint8List.fromList(protocolName.codeUnits);
  Uint8List h = Uint8List(32);
  if (pn.length <= 32) {
    h.setRange(0, pn.length, pn);
  } else {
    return _sha256Sync(pn);
  }
  return h;
}

// Internal helpers below are async because the cryptography package's
// hashing API is async. We re-export them via [HandshakeState] methods.

(Uint8List, Uint8List) _hkdf2(Uint8List chainingKey, Uint8List ikm) {
  // HKDF with HMAC-SHA-256, emitting two 32-byte outputs. We hand-roll
  // because the cryptography package's Hkdf doesn't match Noise's
  // chunked-info expand pattern out of the box.
  Uint8List temp = _hmacSha256(chainingKey, ikm);
  Uint8List out1 = _hmacSha256(temp, Uint8List.fromList(<int>[0x01]));
  BytesBuilder bb = BytesBuilder();
  bb.add(out1);
  bb.addByte(0x02);
  Uint8List out2 = _hmacSha256(temp, bb.toBytes());
  return (out1, out2);
}

// HMAC-SHA-256 hand-rolled on top of `_sha256Sync`. We avoid the async
// hmac builders because they're 100x slower for this small hot path.
Uint8List _hmacSha256(Uint8List key, Uint8List data) {
  const int blockSize = 64;
  Uint8List k = key;
  if (k.length > blockSize) {
    k = _sha256Sync(k);
  }
  if (k.length < blockSize) {
    Uint8List padded = Uint8List(blockSize);
    padded.setRange(0, k.length, k);
    k = padded;
  }
  Uint8List ipad = Uint8List(blockSize);
  Uint8List opad = Uint8List(blockSize);
  for (int i = 0; i < blockSize; i++) {
    ipad[i] = k[i] ^ 0x36;
    opad[i] = k[i] ^ 0x5C;
  }
  Uint8List inner;
  {
    BytesBuilder bb = BytesBuilder();
    bb.add(ipad);
    bb.add(data);
    inner = _sha256Sync(bb.toBytes());
  }
  BytesBuilder bb = BytesBuilder();
  bb.add(opad);
  bb.add(inner);
  return _sha256Sync(bb.toBytes());
}

/// Pure-Dart SHA-256. We hand-roll because the `cryptography` package's
/// hashing API is async, and `_mixHash` (called many times per
/// handshake) would otherwise have to bubble up Futures everywhere.
Uint8List _sha256Sync(Uint8List data) {
  // Initial hash values (first 32 bits of fractional parts of sqrt(2..19)).
  const List<int> initialH = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  const List<int> kConst = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  // Pre-processing: pad to multiple of 64 bytes.
  int origLen = data.length;
  int paddedLen = origLen + 1;
  paddedLen += (56 - paddedLen % 64 + 64) % 64;
  paddedLen += 8;
  Uint8List padded = Uint8List(paddedLen);
  padded.setRange(0, origLen, data);
  padded[origLen] = 0x80;
  int bitLen = origLen * 8;
  for (int i = 0; i < 8; i++) {
    padded[paddedLen - 1 - i] = (bitLen >> (i * 8)) & 0xFF;
  }

  List<int> h = List<int>.from(initialH);
  for (int chunk = 0; chunk < paddedLen; chunk += 64) {
    List<int> w = List<int>.filled(64, 0);
    for (int i = 0; i < 16; i++) {
      int o = chunk + i * 4;
      w[i] = (padded[o] << 24) |
          (padded[o + 1] << 16) |
          (padded[o + 2] << 8) |
          padded[o + 3];
    }
    for (int i = 16; i < 64; i++) {
      int s0 =
          _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      int s1 =
          _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    int a = h[0], b = h[1], c = h[2], d = h[3];
    int e = h[4], f = h[5], g = h[6], hh = h[7];
    for (int i = 0; i < 64; i++) {
      int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      int ch = (e & f) ^ (~e & 0xFFFFFFFF & g);
      int temp1 = (hh + s1 + ch + kConst[i] + w[i]) & 0xFFFFFFFF;
      int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      int maj = (a & b) ^ (a & c) ^ (b & c);
      int temp2 = (s0 + maj) & 0xFFFFFFFF;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xFFFFFFFF;
    }
    h[0] = (h[0] + a) & 0xFFFFFFFF;
    h[1] = (h[1] + b) & 0xFFFFFFFF;
    h[2] = (h[2] + c) & 0xFFFFFFFF;
    h[3] = (h[3] + d) & 0xFFFFFFFF;
    h[4] = (h[4] + e) & 0xFFFFFFFF;
    h[5] = (h[5] + f) & 0xFFFFFFFF;
    h[6] = (h[6] + g) & 0xFFFFFFFF;
    h[7] = (h[7] + hh) & 0xFFFFFFFF;
  }
  Uint8List out = Uint8List(32);
  for (int i = 0; i < 8; i++) {
    out[i * 4] = (h[i] >> 24) & 0xFF;
    out[i * 4 + 1] = (h[i] >> 16) & 0xFF;
    out[i * 4 + 2] = (h[i] >> 8) & 0xFF;
    out[i * 4 + 3] = h[i] & 0xFF;
  }
  return out;
}

int _rotr(int v, int n) {
  v &= 0xFFFFFFFF;
  return ((v >>> n) | (v << (32 - n))) & 0xFFFFFFFF;
}

/// 12-byte ChaCha20-Poly1305 nonce: 4 zero bytes + little-endian u64.
Uint8List _nonce12(int counter) {
  Uint8List out = Uint8List(12);
  ByteData bd = ByteData.sublistView(out, 4);
  bd.setUint64(0, counter, Endian.little);
  return out;
}

Future<Uint8List> _x25519(Uint8List priv, Uint8List pub) async {
  X25519 algo = X25519();
  SimpleKeyPair kp = await algo.newKeyPairFromSeed(priv);
  SimplePublicKey peer = SimplePublicKey(pub, type: KeyPairType.x25519);
  SecretKey shared = await algo.sharedSecretKey(keyPair: kp, remotePublicKey: peer);
  List<int> bytes = await shared.extractBytes();
  // Reject all-zero shared secrets per Noise spec.
  bool allZero = true;
  for (int b in bytes) {
    if (b != 0) {
      allZero = false;
      break;
    }
  }
  if (allZero) {
    throw StateError('crypto: X25519 output is all-zero');
  }
  return Uint8List.fromList(bytes);
}

/// Convenience helper used by both `seal.dart` and the cross-language tests.
Uint8List noiseNonce12(int counter) => _nonce12(counter);

/// Convenience helper for the seal layer and replay logic.
Uint8List sha256Sync(Uint8List data) => _sha256Sync(data);

/// Convenience helper for the seal layer.
(Uint8List, Uint8List) hkdf2(Uint8List chainingKey, Uint8List ikm) =>
    _hkdf2(chainingKey, ikm);
