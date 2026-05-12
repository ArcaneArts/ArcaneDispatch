import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'pair_session.dart';

/// A real-network [PairChannel] backed by a single TCP socket.
///
/// Wire format mirrors the contract documented on the abstract
/// [PairChannel]: every logical handshake frame is prefixed with a
/// two-byte big-endian length so we don't depend on TCP boundaries.
///
/// We deliberately keep this small — the Pair & Share handshake is
/// exactly two frames (one from initiator, one from responder), so the
/// channel only has to survive long enough to ferry those before
/// [PairSession] hands its [NoiseTransport] back to the bonded session.
///
/// On the host side, callers typically pair a [ServerSocket] with
/// [TcpPairChannel.accept] to await one incoming joiner. On the joiner
/// side, [TcpPairChannel.connect] dials a known endpoint.
///
/// **Threading**: each instance is single-owner. Calling [recv] twice
/// concurrently or from two isolates is undefined; the implementation
/// uses a [StreamIterator] under the hood and will throw.
class TcpPairChannel implements PairChannel {
  /// The connected socket. Marked late because [accept] / [connect]
  /// fill it in before any [send] / [recv] is reachable.
  final Socket _socket;

  /// Buffered inbound bytes — incoming TCP fragments accumulate here
  /// until we have a full length-prefixed frame to hand back to [recv].
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// Pending requests for [recv]. Resolved in order as full frames
  /// arrive. We use a queue so the handshake — which alternates send /
  /// recv with no overlap — never races itself, but a defensive
  /// implementation costs almost nothing.
  final List<Completer<Uint8List>> _pending = <Completer<Uint8List>>[];

  StreamSubscription<List<int>>? _sub;
  bool _closed = false;
  Object? _error;

  TcpPairChannel._(this._socket) {
    _sub = _socket.listen(
      _onBytes,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  /// Dial [host]:[port] and wrap the resulting [Socket]. Times out
  /// after [timeout] if the responder isn't listening.
  ///
  /// On failure throws [PairException] (never a raw [SocketException])
  /// so the UI layer can surface a clean error message regardless of
  /// the underlying transport.
  static Future<TcpPairChannel> connect(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    try {
      Socket s = await Socket.connect(host, port, timeout: timeout);
      // Nagle's algorithm adds latency that the two-frame handshake
      // doesn't benefit from — flush every write immediately.
      s.setOption(SocketOption.tcpNoDelay, true);
      return TcpPairChannel._(s);
    } on SocketException catch (e) {
      throw PairException('TCP connect to $host:$port failed: ${e.message}');
    } on TimeoutException {
      throw PairException('TCP connect to $host:$port timed out');
    }
  }

  /// Wrap an already-accepted server-side [Socket]. Hosts typically do
  /// `await for (Socket s in serverSocket) { TcpPairChannel.accept(s); }`.
  /// Returns immediately — [recv] starts buffering whatever bytes the
  /// peer has already sent.
  factory TcpPairChannel.accept(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    return TcpPairChannel._(socket);
  }

  @override
  Future<void> send(Uint8List frame) async {
    if (_closed) throw const PairException('channel closed');
    if (frame.length > 0xFFFF) {
      throw PairException('frame too large: ${frame.length} bytes');
    }
    Uint8List header = Uint8List(2);
    header[0] = (frame.length >> 8) & 0xFF;
    header[1] = frame.length & 0xFF;
    _socket.add(header);
    _socket.add(frame);
    await _socket.flush();
  }

  @override
  Future<Uint8List> recv() async {
    if (_error != null) throw _error!;
    Uint8List? immediate = _tryDrainFrame();
    if (immediate != null) return immediate;
    if (_closed) {
      throw const PairException('channel closed mid-handshake');
    }
    Completer<Uint8List> c = Completer<Uint8List>();
    _pending.add(c);
    return c.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub?.cancel();
    _sub = null;
    try {
      await _socket.close();
    } catch (_) {
      // Ignore — best-effort teardown.
    }
    // Reject any pending recv waiters so they don't hang forever.
    for (Completer<Uint8List> c in _pending) {
      if (!c.isCompleted) {
        c.completeError(const PairException('channel closed'));
      }
    }
    _pending.clear();
  }

  void _onBytes(List<int> data) {
    _buffer.add(data);
    _drain();
  }

  void _onError(Object error, StackTrace? st) {
    _error = error is PairException
        ? error
        : PairException('TCP error: $error');
    for (Completer<Uint8List> c in _pending) {
      if (!c.isCompleted) c.completeError(_error!);
    }
    _pending.clear();
  }

  void _onDone() {
    _closed = true;
    _drain();
    if (_pending.isNotEmpty) {
      for (Completer<Uint8List> c in _pending) {
        if (!c.isCompleted) {
          c.completeError(const PairException('channel closed mid-handshake'));
        }
      }
      _pending.clear();
    }
  }

  /// Pop one full frame from the buffer if possible.
  Uint8List? _tryDrainFrame() {
    Uint8List view = _buffer.toBytes();
    if (view.length < 2) {
      _buffer.clear();
      _buffer.add(view);
      return null;
    }
    int len = (view[0] << 8) | view[1];
    if (view.length < 2 + len) {
      _buffer.clear();
      _buffer.add(view);
      return null;
    }
    Uint8List frame = Uint8List.sublistView(view, 2, 2 + len);
    Uint8List leftover = Uint8List.sublistView(view, 2 + len);
    _buffer.clear();
    if (leftover.isNotEmpty) _buffer.add(leftover);
    return Uint8List.fromList(frame);
  }

  /// Drain as many buffered frames as possible into pending [recv] waiters.
  void _drain() {
    while (_pending.isNotEmpty) {
      Uint8List? frame = _tryDrainFrame();
      if (frame == null) break;
      Completer<Uint8List> c = _pending.removeAt(0);
      if (!c.isCompleted) c.complete(frame);
    }
  }
}
