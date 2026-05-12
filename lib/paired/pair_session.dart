import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/link.dart';
import '../crypto/noise.dart';
import 'pair_beacon.dart';

/// Outcome of a Pair & Share handshake. Both sides surface the same
/// shape so the UI can render symmetric "approve / reject" prompts.
class PairOutcome {
  /// The fully-validated peer link, ready to be merged into [Policy.links].
  /// `kind` is always [LinkKind.paired]; `pairedEndpoint`/`pairedFingerprint`
  /// are filled in.
  final Link link;

  /// Transport context returned by the underlying Noise handshake. The
  /// caller owns its lifecycle and pipes packets through it.
  final NoiseTransport transport;

  /// 6-digit numeric code derived from the transcript hash. The user
  /// must read this off both screens to confirm the handshake wasn't
  /// intercepted. Identical on both sides when no MITM is present.
  final String verifyCode;

  /// First 16 hex chars of SHA-256(peer.static.public). Same value that
  /// `PairBeacon.fingerprint` advertises; redundantly recomputed here so
  /// callers can trust this rather than the (untrusted) advertisement.
  final String peerFingerprint;

  const PairOutcome({
    required this.link,
    required this.transport,
    required this.verifyCode,
    required this.peerFingerprint,
  });
}

/// Failure during a handshake. Exposed as a thrown exception so we don't
/// silently produce an unauthenticated [PairedLink].
class PairException implements Exception {
  final String message;
  const PairException(this.message);
  @override
  String toString() => 'PairException: $message';
}

/// Abstract duplex byte channel used to ferry the two handshake
/// messages. In production this is a TCP socket on port `port+1`; tests
/// inject a `LoopbackPairChannel` to short-circuit the wire.
///
/// The session writes exactly one frame in each direction. Each frame is
/// prefixed by a 2-byte big-endian length so we don't depend on TCP
/// boundaries.
abstract class PairChannel {
  /// Send [frame] verbatim. Returns once the bytes have been handed off
  /// to the OS (or the loopback peer for fakes).
  Future<void> send(Uint8List frame);

  /// Receive the next frame. Completes with the entire payload or
  /// throws if the channel closes / times out.
  Future<Uint8List> recv();

  /// Close the channel. Idempotent.
  Future<void> close();
}

/// Drives a Pair & Share handshake.
///
/// The Noise IK static keys identify each *device*; the resulting
/// [NoiseTransport] is then used by the bonded session to seal every
/// packet relayed via the peer's internet uplink.
///
/// Static usage:
///
///     // Joiner (initiator): we know the host's advertised fingerprint
///     // from a Bonjour beacon.
///     PairOutcome o = await PairSession.join(
///       channel: tcp,
///       me: myKeypair,
///       beacon: discovered,
///     );
///
///     // Host (responder):
///     PairOutcome o = await PairSession.host(
///       channel: tcp,
///       me: myKeypair,
///       hostName: 'My Mac',
///       endpoint: '10.0.0.5:44430',
///     );
class PairSession {
  PairSession._();

  /// Drive the initiator side. The caller already knows the responder's
  /// advertised X25519 public key (carried by the Bonjour [PairBeacon])
  /// and contributes its own [NoiseKeypair].
  ///
  /// Throws [PairException] on any of:
  ///  * malformed/short frames
  ///  * fingerprint mismatch between [beacon] and the key we actually
  ///    received in the response payload
  ///  * AEAD verification failure (cryptographic abort)
  static Future<PairOutcome> join({
    required PairChannel channel,
    required NoiseKeypair me,
    required PairBeacon beacon,
    required Uint8List remoteStatic,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    HandshakeState hs = await HandshakeState.initiator(s: me, rs: remoteStatic);
    Uint8List msg1 =
        await hs.writeMessage1(_encodeJoiner(me.public, deviceName: _hostName()));
    await channel.send(msg1);

    Uint8List msg2 = await channel.recv().timeout(
      timeout,
      onTimeout: () => throw const PairException('responder timed out'),
    );
    ({Uint8List payload, NoiseTransport transport}) r =
        await hs.readMessage2(msg2);
    _HostPayload host = _decodeHost(r.payload);

    String fp = await _fingerprint(remoteStatic);
    if (beacon.fingerprint.isNotEmpty &&
        beacon.fingerprint.toLowerCase() != fp.toLowerCase()) {
      throw PairException(
          'fingerprint mismatch: beacon=${beacon.fingerprint} actual=$fp');
    }

    Link link = Link(
      id: 'paired:${beacon.deviceId}',
      label: host.deviceName.isNotEmpty ? host.deviceName : beacon.deviceName,
      priority: LinkPriority.secondary,
      weight: 1,
      kind: LinkKind.paired,
      pairedEndpoint: '${beacon.host}:${beacon.port}',
      pairedFingerprint: fp,
    );

    return PairOutcome(
      link: link,
      transport: r.transport,
      verifyCode: hs.transcriptHashShortCode(),
      peerFingerprint: fp,
    );
  }

  /// Drive the responder side. The caller (the device that's *sharing*
  /// its uplink) accepts whatever ephemeral the joiner sends and seals
  /// its identity into the response.
  static Future<PairOutcome> host({
    required PairChannel channel,
    required NoiseKeypair me,
    required String hostName,
    required String endpoint,
    String? hostDeviceId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    HandshakeState hs = await HandshakeState.responder(s: me);

    Uint8List msg1 = await channel.recv().timeout(
      timeout,
      onTimeout: () => throw const PairException('initiator timed out'),
    );
    Uint8List payload = await hs.readMessage1(msg1);
    _JoinerPayload joiner = _decodeJoiner(payload);

    ({Uint8List msg, NoiseTransport transport}) w = await hs.writeMessage2(
      _encodeHost(deviceName: hostName, endpoint: endpoint),
    );
    await channel.send(w.msg);

    String fp = await _fingerprint(joiner.publicKey);
    String pairedId = hostDeviceId ?? 'remote:$fp';
    Link link = Link(
      id: 'paired:$pairedId',
      label: joiner.deviceName.isNotEmpty ? joiner.deviceName : 'Paired peer',
      priority: LinkPriority.secondary,
      weight: 1,
      kind: LinkKind.paired,
      pairedEndpoint: endpoint,
      pairedFingerprint: fp,
    );

    return PairOutcome(
      link: link,
      transport: w.transport,
      verifyCode: hs.transcriptHashShortCode(),
      peerFingerprint: fp,
    );
  }

  /// Returns the first 16 hex chars of SHA-256(rawPublicKey). Used as
  /// the human-presentable peer identity in the UI and in [Link.pairedFingerprint].
  static Future<String> fingerprintOf(Uint8List rawPublicKey) =>
      _fingerprint(rawPublicKey);
}

/// In-process channel used by tests + Local Mode. `a` and `b` are
/// cross-linked so a write on one is a read on the other.
class LoopbackPairChannel implements PairChannel {
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  late LoopbackPairChannel _peer;
  bool _closed = false;
  late final StreamIterator<Uint8List> _iter =
      StreamIterator<Uint8List>(_in.stream);

  /// Returns a connected `(a, b)` pair sharing a single in-memory pipe.
  static (LoopbackPairChannel, LoopbackPairChannel) pair() {
    LoopbackPairChannel a = LoopbackPairChannel._();
    LoopbackPairChannel b = LoopbackPairChannel._();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  LoopbackPairChannel._();

  @override
  Future<void> send(Uint8List frame) async {
    if (_peer._closed) {
      throw const PairException('peer channel closed');
    }
    _peer._in.add(Uint8List.fromList(frame));
  }

  @override
  Future<Uint8List> recv() async {
    bool ok = await _iter.moveNext();
    if (!ok) {
      throw const PairException('channel closed mid-handshake');
    }
    return _iter.current;
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _in.close();
  }
}

// --- Payload encoding ------------------------------------------------------

class _JoinerPayload {
  final Uint8List publicKey;
  final String deviceName;
  _JoinerPayload(this.publicKey, this.deviceName);
}

class _HostPayload {
  final String deviceName;
  final String endpoint;
  _HostPayload(this.deviceName, this.endpoint);
}

Uint8List _encodeJoiner(Uint8List publicKey, {required String deviceName}) {
  List<int> nameBytes = _utf8(deviceName, max: 80);
  ByteData buf = ByteData(2 + publicKey.length + 1 + nameBytes.length);
  buf.setUint16(0, publicKey.length);
  buf.buffer.asUint8List().setRange(2, 2 + publicKey.length, publicKey);
  buf.setUint8(2 + publicKey.length, nameBytes.length);
  buf.buffer
      .asUint8List()
      .setRange(2 + publicKey.length + 1,
          2 + publicKey.length + 1 + nameBytes.length, nameBytes);
  return buf.buffer.asUint8List();
}

_JoinerPayload _decodeJoiner(Uint8List bytes) {
  if (bytes.length < 3) {
    throw const PairException('joiner payload too short');
  }
  ByteData view = ByteData.sublistView(bytes);
  int pubLen = view.getUint16(0);
  if (pubLen != 32 || 2 + pubLen + 1 > bytes.length) {
    throw const PairException('joiner public key length invalid');
  }
  Uint8List pub = Uint8List.sublistView(bytes, 2, 2 + pubLen);
  int nameLen = view.getUint8(2 + pubLen);
  int nameStart = 2 + pubLen + 1;
  if (nameStart + nameLen > bytes.length) {
    throw const PairException('joiner name overruns payload');
  }
  String name = String.fromCharCodes(bytes, nameStart, nameStart + nameLen);
  return _JoinerPayload(Uint8List.fromList(pub), name);
}

Uint8List _encodeHost(
    {required String deviceName, required String endpoint}) {
  List<int> name = _utf8(deviceName, max: 80);
  List<int> ep = _utf8(endpoint, max: 80);
  ByteData buf = ByteData(1 + name.length + 1 + ep.length);
  buf.setUint8(0, name.length);
  buf.buffer.asUint8List().setRange(1, 1 + name.length, name);
  buf.setUint8(1 + name.length, ep.length);
  buf.buffer
      .asUint8List()
      .setRange(1 + name.length + 1, 1 + name.length + 1 + ep.length, ep);
  return buf.buffer.asUint8List();
}

_HostPayload _decodeHost(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const PairException('host payload empty');
  }
  int nameLen = bytes[0];
  if (1 + nameLen + 1 > bytes.length) {
    throw const PairException('host name overruns payload');
  }
  String name = String.fromCharCodes(bytes, 1, 1 + nameLen);
  int epLen = bytes[1 + nameLen];
  int epStart = 1 + nameLen + 1;
  if (epStart + epLen > bytes.length) {
    throw const PairException('host endpoint overruns payload');
  }
  String endpoint = String.fromCharCodes(bytes, epStart, epStart + epLen);
  return _HostPayload(name, endpoint);
}

List<int> _utf8(String value, {required int max}) {
  List<int> raw = value.codeUnits;
  if (raw.length > max) {
    raw = raw.sublist(0, max);
  }
  return raw;
}

Future<String> _fingerprint(Uint8List publicKey) async {
  Sha256 sha = Sha256();
  Hash h = await sha.hash(publicKey);
  StringBuffer out = StringBuffer();
  for (int i = 0; i < 8 && i < h.bytes.length; i++) {
    out.write(h.bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return out.toString();
}

String _hostName() => 'ArcaneDispatch';

/// Convenience extension exposing the transcript hash as a numeric
/// "phone-confirm" code. Stable across initiator/responder when the
/// handshake completed without tampering.
extension HandshakeStateVerifyCode on HandshakeState {
  String transcriptHashShortCode() {
    Uint8List h = transcriptHash();
    int n = (h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
    int code = (n.abs()) % 1000000;
    return code.toString().padLeft(6, '0');
  }
}
