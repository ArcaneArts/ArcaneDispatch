import 'dart:async';
import 'dart:typed_data';

import '../crypto/noise.dart';
import 'paired_datagram.dart';

/// Pluggable internet egress used by [PairedBridge]. In production this
/// is a `RawDatagramSocket` bound to the sharer's real interface; in
/// tests we inject a fake that records or echoes packets.
///
/// `bytes` is the *inner* packet (already decrypted by the bridge). The
/// forwarder owns address translation: it is responsible for relaying
/// the packet to the actual internet and turning around any response
/// via the `onResponse` callback registered at bind time.
abstract class PairedBridgeForwarder {
  /// Forward [bytes] received from [fromDeviceId]. The implementation
  /// may complete immediately (fire-and-forget) or asynchronously.
  Future<void> forward(
    Uint8List bytes, {
    required String fromDeviceId,
  });

  /// Subscribe to upstream responses. The bridge re-seals these and
  /// ships them back to the originating joiner.
  Stream<PairedBridgeResponse> get responses;

  /// Free underlying sockets / pumps. Idempotent.
  Future<void> close();
}

class PairedBridgeResponse {
  /// Stable deviceId of the joiner the response should be returned to.
  final String toDeviceId;

  /// Plaintext packet to seal + ship back.
  final Uint8List bytes;

  const PairedBridgeResponse({required this.toDeviceId, required this.bytes});
}

/// One paired peer the bridge knows about. The bridge keeps a per-peer
/// Noise transport + return path so multiple joiners can share the same
/// sharer concurrently.
class PairedPeerRoute {
  /// Stable deviceId of the joiner.
  final String deviceId;

  /// The Noise transport returned by `PairSession.host(...)`. Owns the
  /// per-peer send/recv keys.
  final NoiseTransport transport;

  /// Where to ship sealed bytes back to. Populated lazily from the most
  /// recent inbound packet from this peer.
  String? lastFromHost;
  int? lastFromPort;

  /// Inbound packet counter used to gate replay attacks. Each successful
  /// open advances the counter; older nonces are rejected.
  int highestNonceSeen = -1;

  PairedPeerRoute({required this.deviceId, required this.transport});
}

/// Stats surface for tests + the UI.
class PairedBridgeStats {
  final int peersAttached;
  final int packetsAccepted;
  final int packetsRejected;
  final int packetsForwarded;
  final int responsesShipped;

  const PairedBridgeStats({
    required this.peersAttached,
    required this.packetsAccepted,
    required this.packetsRejected,
    required this.packetsForwarded,
    required this.responsesShipped,
  });

  @override
  String toString() =>
      'PairedBridgeStats(peers=$peersAttached, accepted=$packetsAccepted, '
      'rejected=$packetsRejected, fwd=$packetsForwarded, resp=$responsesShipped)';
}

/// The Pair & Share *sharer* role.
///
/// Accepts sealed bonded frames over [PairedDatagram] from any attached
/// joiner, opens them with the corresponding [NoiseTransport], hands the
/// plaintext to a [PairedBridgeForwarder], and ships responses back.
///
/// Wire format (per datagram):
///
///     0     8                len
///     +-----+------------------+
///     |dvId |  sealed payload  |
///     +-----+------------------+
///
/// where `dvId` is the first 8 bytes of the joiner's deviceId (UTF-8,
/// right-padded with zeros). This lets the bridge demux without
/// resorting to a separate handshake-per-frame.
class PairedBridge {
  final PairedDatagram socket;
  final PairedBridgeForwarder forwarder;
  final Map<String, PairedPeerRoute> _peers = <String, PairedPeerRoute>{};
  StreamSubscription<PairedDatagramEvent>? _ingress;
  StreamSubscription<PairedBridgeResponse>? _egress;
  int _accepted = 0;
  int _rejected = 0;
  int _forwarded = 0;
  int _responsesShipped = 0;
  bool _closed = false;

  PairedBridge({required this.socket, required this.forwarder});

  /// Attach a freshly-paired peer. Call once per `PairSession.host()`
  /// completion. Replaces any prior route for the same deviceId.
  void attachPeer(PairedPeerRoute route) {
    _peers[route.deviceId] = route;
  }

  /// Drop a paired peer. Subsequent traffic from them is rejected.
  void detachPeer(String deviceId) {
    _peers.remove(deviceId);
  }

  PairedBridgeStats get stats => PairedBridgeStats(
        peersAttached: _peers.length,
        packetsAccepted: _accepted,
        packetsRejected: _rejected,
        packetsForwarded: _forwarded,
        responsesShipped: _responsesShipped,
      );

  /// Begin pumping. The bridge runs until [close] is called.
  Future<void> start() async {
    if (_ingress != null) {
      throw StateError('bridge already started');
    }
    _ingress = socket.inbound.listen(_onPacket);
    _egress = forwarder.responses.listen(_onResponse);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _ingress?.cancel();
    await _egress?.cancel();
    _ingress = null;
    _egress = null;
    await forwarder.close();
    await socket.close();
    _peers.clear();
  }

  // --- ingress ---

  Future<void> _onPacket(PairedDatagramEvent evt) async {
    if (evt.bytes.length < 8 + 16) {
      _rejected++;
      return;
    }
    String header = _decodeHeader(evt.bytes);
    PairedPeerRoute? route = _peers[header];
    if (route == null) {
      _rejected++;
      return;
    }
    int nonceOffset = 8;
    int nonce = _readUint64(evt.bytes, nonceOffset);
    int payloadOffset = nonceOffset + 8;
    if (nonce <= route.highestNonceSeen) {
      _rejected++;
      return;
    }
    // Claim the nonce slot synchronously before awaiting the AEAD work
    // so concurrent in-flight `_onPacket` calls correctly reject replays.
    route.highestNonceSeen = nonce;
    Uint8List payload = Uint8List.sublistView(evt.bytes, payloadOffset);
    Uint8List opened;
    try {
      opened = await route.transport.open(nonce, null, payload);
    } catch (_) {
      _rejected++;
      return;
    }
    route.lastFromHost = evt.fromHost;
    route.lastFromPort = evt.fromPort;
    _accepted++;
    try {
      await forwarder.forward(opened, fromDeviceId: route.deviceId);
      _forwarded++;
    } catch (_) {
      // Forwarder errors don't propagate — best-effort relay.
    }
  }

  Future<void> _onResponse(PairedBridgeResponse resp) async {
    PairedPeerRoute? route = _peers[resp.toDeviceId];
    if (route == null) return;
    String? host = route.lastFromHost;
    int? port = route.lastFromPort;
    if (host == null || port == null) return;
    ({int nonce, Uint8List ciphertext}) sealed =
        await route.transport.seal(null, resp.bytes);
    Uint8List frame = Uint8List(8 + 8 + sealed.ciphertext.length);
    _writeHeader(frame, resp.toDeviceId);
    _writeUint64(frame, 8, sealed.nonce);
    frame.setRange(16, frame.length, sealed.ciphertext);
    await socket.send(frame, toHost: host, toPort: port);
    _responsesShipped++;
  }

  // --- helpers ---

  static String _decodeHeader(Uint8List bytes) {
    int end = 8;
    for (int i = 0; i < 8; i++) {
      if (bytes[i] == 0) {
        end = i;
        break;
      }
    }
    return String.fromCharCodes(bytes, 0, end);
  }

  static void _writeHeader(Uint8List dst, String deviceId) {
    List<int> raw = deviceId.codeUnits;
    int n = raw.length > 8 ? 8 : raw.length;
    for (int i = 0; i < n; i++) {
      dst[i] = raw[i] & 0xff;
    }
    for (int i = n; i < 8; i++) {
      dst[i] = 0;
    }
  }

  static int _readUint64(Uint8List bytes, int offset) {
    int v = 0;
    for (int i = 0; i < 8; i++) {
      v = (v << 8) | bytes[offset + i];
    }
    return v;
  }

  static void _writeUint64(Uint8List dst, int offset, int value) {
    for (int i = 7; i >= 0; i--) {
      dst[offset + i] = value & 0xff;
      value >>= 8;
    }
  }
}

/// Trivial forwarder used by tests + local mode previews. Just records
/// every forwarded packet and lets the test push synthetic responses.
class RecordingPairedBridgeForwarder implements PairedBridgeForwarder {
  final List<Uint8List> forwarded = <Uint8List>[];
  final List<String> fromDevices = <String>[];
  final StreamController<PairedBridgeResponse> _resp =
      StreamController<PairedBridgeResponse>.broadcast();
  bool _closed = false;

  @override
  Future<void> forward(
    Uint8List bytes, {
    required String fromDeviceId,
  }) async {
    forwarded.add(Uint8List.fromList(bytes));
    fromDevices.add(fromDeviceId);
  }

  /// Push a synthetic response. Useful in tests for the round-trip path.
  void injectResponse(PairedBridgeResponse resp) {
    if (_closed) return;
    _resp.add(resp);
  }

  @override
  Stream<PairedBridgeResponse> get responses => _resp.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _resp.close();
  }
}
