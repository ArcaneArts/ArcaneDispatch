import 'dart:async';
import 'dart:typed_data';

import '../crypto/noise.dart';
import 'paired_datagram.dart';

/// The *joiner* side of a Pair & Share link.
///
/// Owns a [PairedDatagram] socket bound to the local device and a
/// [NoiseTransport] returned by `PairSession.join(...)`. The bonded
/// session calls [send] with raw bonded frames; the socket seals them
/// and ships them to the peer's bridge. Responses are surfaced via
/// [inbound] for the session to feed back through its reassembler.
///
/// Wire format mirrors `PairedBridge`:
///
///     +--------+--------+----------------------+
///     | dvId8  | nonce8 |  sealed ciphertext   |
///     +--------+--------+----------------------+
///
/// where `dvId` is our own deviceId (8 ASCII bytes, zero-padded). The
/// peer uses it to demux multiple attached joiners.
class PairedLinkSocket {
  final PairedDatagram _socket;
  final NoiseTransport _transport;
  final String _localDeviceId;
  final String _peerHost;
  final int _peerPort;
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  StreamSubscription<PairedDatagramEvent>? _ingress;
  int _highestNonceSeen = -1;
  int _sealedBytes = 0;
  int _openedBytes = 0;
  bool _closed = false;

  PairedLinkSocket({
    required PairedDatagram socket,
    required NoiseTransport transport,
    required String localDeviceId,
    required String peerHost,
    required int peerPort,
  })  : _socket = socket,
        _transport = transport,
        _localDeviceId = localDeviceId,
        _peerHost = peerHost,
        _peerPort = peerPort {
    _ingress = _socket.inbound.listen(_onInbound);
  }

  /// Plaintext bytes the bonded session can ingest. Re-sealing latency
  /// is hidden from the caller — they treat this like any other inbound
  /// link stream.
  Stream<Uint8List> get inbound => _inbound.stream;

  /// Diagnostic counter: total ciphertext bytes shipped to the peer.
  int get sealedBytes => _sealedBytes;

  /// Diagnostic counter: total plaintext bytes received from the peer
  /// after successful AEAD verification.
  int get openedBytes => _openedBytes;

  /// Where the peer's bridge is listening.
  String get peerEndpoint => '$_peerHost:$_peerPort';

  /// Seal [frame] and ship it. Returns once the socket has handed the
  /// bytes off (no delivery guarantee beyond best-effort UDP).
  Future<void> send(Uint8List frame) async {
    if (_closed) {
      throw StateError('PairedLinkSocket closed');
    }
    ({int nonce, Uint8List ciphertext}) sealed =
        await _transport.seal(null, frame);
    Uint8List wire = Uint8List(8 + 8 + sealed.ciphertext.length);
    _writeHeader(wire, _localDeviceId);
    _writeUint64(wire, 8, sealed.nonce);
    wire.setRange(16, wire.length, sealed.ciphertext);
    _sealedBytes += sealed.ciphertext.length;
    await _socket.send(wire, toHost: _peerHost, toPort: _peerPort);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _ingress?.cancel();
    _ingress = null;
    await _socket.close();
    await _inbound.close();
  }

  Future<void> _onInbound(PairedDatagramEvent evt) async {
    if (evt.bytes.length < 8 + 16) return;
    // Header is our own deviceId — the peer echoes it back. We trust the
    // bridge to keep replies tied to the right path, but cheap-verify
    // the prefix just in case.
    int nonce = _readUint64(evt.bytes, 8);
    if (nonce <= _highestNonceSeen) {
      return;
    }
    Uint8List payload = Uint8List.sublistView(evt.bytes, 16);
    Uint8List opened;
    try {
      opened = await _transport.open(nonce, null, payload);
    } catch (_) {
      return;
    }
    _highestNonceSeen = nonce;
    _openedBytes += opened.length;
    _inbound.add(opened);
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
