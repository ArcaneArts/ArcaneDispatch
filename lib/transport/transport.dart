import 'dart:async';

import '../core/flow_stat.dart';
import '../core/link_metric.dart';
import '../core/policy.dart';
import '../core/proxy_event.dart';

/// Lifecycle state of a [Transport].
///
/// State transitions are linear forward (`stopped` → `starting` → `running`
/// → `stopping` → `stopped`) with `failed` as a sink that any state can fall
/// into. Consumers should treat `failed` as terminal for that *attempt*; the
/// transport may be restarted by calling [Transport.start] again.
enum TransportState { stopped, starting, running, stopping, failed }

/// Wire-level snapshot of a [Transport]'s status.
///
/// Emitted by [Transport.states]. Carries enough info for the UI to render
/// the connect/disconnect button and surface error banners without needing
/// to poll for individual fields.
class TransportStatus {
  final TransportState state;
  final String? endpoint;
  final String? errorMessage;
  final DateTime since;

  TransportStatus({
    required this.state,
    this.endpoint,
    this.errorMessage,
    DateTime? since,
  }) : since = since ?? DateTime.now();

  bool get isRunning {
    return state == TransportState.running;
  }

  bool get isBusy {
    return state == TransportState.starting || state == TransportState.stopping;
  }

  @override
  String toString() {
    return 'TransportStatus(state=$state, endpoint=$endpoint, error=$errorMessage)';
  }
}

/// Identity of a [Transport] implementation. Used by the [DispatchController]
/// to decide which transport class to instantiate when the user toggles
/// between legacy SOCKS and the bonded tunnel.
enum TransportKind {
  /// Legacy SOCKS4/5 proxy. Apps opt-in via configuration.
  socks,

  /// System-wide bonded tunnel via the macOS Network Extension. Apps need
  /// no configuration. Implementation lives behind [TunnelTransport].
  tunnel,
}

extension TransportKindCodec on TransportKind {
  String get wireName {
    switch (this) {
      case TransportKind.socks:
        return 'socks';
      case TransportKind.tunnel:
        return 'tunnel';
    }
  }

  static TransportKind parse(
    Object? value, {
    TransportKind fallback = TransportKind.tunnel,
  }) {
    if (value is TransportKind) {
      return value;
    }
    if (value is String) {
      for (TransportKind kind in TransportKind.values) {
        if (kind.wireName == value) {
          return kind;
        }
      }
    }
    return fallback;
  }
}

/// A transport is the *backend* that actually moves user traffic.
///
/// Two implementations live behind this interface:
///
/// * `SocksTransport`  — legacy connection-level SOCKS proxy
///                        (`lib/core/socks_proxy_server.dart`).
/// * `TunnelTransport` — system-wide bonded VPN delegated to the macOS
///                        Network Extension (Phase 5+). Until that ships,
///                        this implementation reports `failed` immediately.
///
/// The transport owns its own lifecycle and emits four broadcast streams:
/// [states], [metrics], [flows], and [events]. All four are safe to listen
/// to before [start] is called; they survive across start/stop cycles.
abstract class Transport {
  /// Stable identity used by the UI / settings.
  TransportKind get kind;

  /// Current lifecycle state. Reads from a cached value; the canonical stream
  /// is [states].
  TransportStatus get status;

  /// Broadcasts whenever [status] changes. Always emits the current value to
  /// new subscribers (replayed via `BehaviorSubject`-style helper).
  Stream<TransportStatus> get states;

  /// Per-link metric samples produced by transport-internal probes. Phase 1
  /// implementations may emit nothing; Phase 2 wires this up.
  Stream<LinkMetric> get metrics;

  /// Per-flow event stream (open / bytes / close). Phase 1 SOCKS transport
  /// emits open + close. Phase 6 tunnel transport emits live byte deltas.
  Stream<FlowStat> get flows;

  /// Loose human-readable event stream for the activity log. Mirrors the
  /// existing [ProxyEvent] shape so the current `_EventsSection` UI keeps
  /// working unchanged.
  Stream<ProxyEvent> get events;

  /// Start the transport. Idempotent: returns immediately if already
  /// running. Throws on configuration errors (e.g. no eligible links).
  Future<void> start(Policy policy);

  /// Stop the transport. Idempotent: returns immediately if not running.
  Future<void> stop();

  /// Push a policy update without restarting. Phase 1 may simply restart;
  /// later phases hot-apply changes.
  Future<void> updatePolicy(Policy policy);

  /// Per-link bytes carried since the start of each link's current billing
  /// cycle. Powers the "Total data used" surface in the Activity tab and the
  /// per-network usage chip on each card.
  ///
  /// Returns an empty map for transports that don't keep their own counters
  /// (e.g. the macOS Tunnel implementation, which gets fed an aggregate
  /// number from the extension's flow stats reader on a separate channel).
  /// Counters survive process restarts via the data meter's Hive storage.
  Map<String, int> dataUsedSnapshot() => const <String, int>{};

  /// Release all resources. The transport must not be used after dispose.
  Future<void> dispose();
}

/// Helper for building broadcast streams with a replayable "latest" value.
///
/// Tiny because `package:rxdart` is overkill for the handful of streams we
/// expose. Pattern:
///
/// ```dart
/// final _state = LatestStream<TransportStatus>(TransportStatus(state: TransportState.stopped));
/// Stream<TransportStatus> get states => _state.stream;
/// _state.add(TransportStatus(state: TransportState.starting));
/// ```
class LatestStream<T> {
  T _value;
  final StreamController<T> _controller = StreamController<T>.broadcast();

  LatestStream(T initial) : _value = initial;

  T get value {
    return _value;
  }

  Stream<T> get stream {
    return _controller.stream;
  }

  /// Subscribe and immediately receive [value] before any future events.
  StreamSubscription<T> listen(
    void Function(T) onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    StreamSubscription<T> subscription = _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    scheduleMicrotask(() => onData(_value));
    return subscription;
  }

  void add(T next) {
    _value = next;
    _controller.add(next);
  }

  Future<void> close() {
    return _controller.close();
  }
}
