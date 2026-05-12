import 'dart:async';
import 'dart:typed_data';

/// Abstract datagram transport used by the Pair & Share bridge.
///
/// Production backs this with `RawDatagramSocket` (UDP). Tests substitute
/// an in-memory loopback so the bridge logic can be exercised without
/// hitting the kernel network stack.
///
/// Conceptually the transport is duplex: a single endpoint can both send
/// to and receive from arbitrary peers. We attach `fromHost`/`fromPort`
/// to inbound packets so the bridge can route responses back to the
/// originating joiner.
abstract class PairedDatagram {
  /// Local endpoint, populated once bound. Format is `host:port`. Useful
  /// for embedding into the advertised `PairBeacon`.
  String get localEndpoint;

  /// All datagrams received since [listen]. Multi-subscription not
  /// required — each transport is single-owner.
  Stream<PairedDatagramEvent> get inbound;

  /// Send [frame] to the given peer. Hosts are resolved synchronously
  /// against a static IP literal in production; tests look up the peer
  /// by `host:port` directly. Returns once the kernel has accepted the
  /// bytes (no delivery guarantees beyond best-effort UDP).
  Future<void> send(
    Uint8List frame, {
    required String toHost,
    required int toPort,
  });

  /// Close the underlying socket. Idempotent.
  Future<void> close();
}

class PairedDatagramEvent {
  final Uint8List bytes;
  final String fromHost;
  final int fromPort;
  const PairedDatagramEvent({
    required this.bytes,
    required this.fromHost,
    required this.fromPort,
  });
}

/// Shared in-memory switchboard used by [InMemoryPairedDatagram]s. Two
/// transports bound to the same registry can exchange packets directly.
class InMemoryDatagramRegistry {
  final Map<String, InMemoryPairedDatagram> _bound =
      <String, InMemoryPairedDatagram>{};

  String _key(String host, int port) => '$host:$port';

  void _bind(InMemoryPairedDatagram d, String host, int port) {
    String k = _key(host, port);
    if (_bound.containsKey(k)) {
      throw StateError('endpoint $k already bound');
    }
    _bound[k] = d;
  }

  void _unbind(String host, int port) {
    _bound.remove(_key(host, port));
  }

  void _send(
    InMemoryPairedDatagram from,
    Uint8List bytes,
    String toHost,
    int toPort,
  ) {
    InMemoryPairedDatagram? dst = _bound[_key(toHost, toPort)];
    if (dst == null) {
      // Mirror real UDP: silently drop unrouted packets.
      return;
    }
    dst._deliver(bytes, from._host, from._port);
  }

  Future<void> dispose() async {
    for (InMemoryPairedDatagram d in List.of(_bound.values)) {
      await d.close();
    }
    _bound.clear();
  }
}

class InMemoryPairedDatagram implements PairedDatagram {
  final InMemoryDatagramRegistry _registry;
  final StreamController<PairedDatagramEvent> _ctrl =
      StreamController<PairedDatagramEvent>.broadcast();
  final String _host;
  final int _port;
  bool _closed = false;

  /// Bind a new in-memory datagram socket. Throws if the address is in
  /// use within the same [InMemoryDatagramRegistry].
  InMemoryPairedDatagram(
    this._registry, {
    required String host,
    required int port,
  })  : _host = host,
        _port = port {
    _registry._bind(this, host, port);
  }

  void _deliver(Uint8List bytes, String fromHost, int fromPort) {
    if (_closed) return;
    _ctrl.add(PairedDatagramEvent(
      bytes: Uint8List.fromList(bytes),
      fromHost: fromHost,
      fromPort: fromPort,
    ));
  }

  @override
  String get localEndpoint => '$_host:$_port';

  @override
  Stream<PairedDatagramEvent> get inbound => _ctrl.stream;

  @override
  Future<void> send(
    Uint8List frame, {
    required String toHost,
    required int toPort,
  }) async {
    if (_closed) {
      throw StateError('socket closed');
    }
    _registry._send(this, frame, toHost, toPort);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _registry._unbind(_host, _port);
    await _ctrl.close();
  }
}
