import 'dart:async';

/// A peer advertised on the local network as available for Pair & Share.
///
/// Production discovery uses Bonjour (`_arcane-dispatch._tcp`) on macOS via
/// `NWBrowser`/`NetService`; this Dart model is the abstract result that
/// the rest of the stack consumes. Tests inject a fake [PairDiscovery] that
/// emits arbitrary [PairBeacon] events without touching the network.
class PairBeacon {
  /// Stable per-device id (UUID generated at first launch). Used as the
  /// dedup key when the same peer is seen on multiple interfaces.
  final String deviceId;

  /// Human-readable name from `~/.config/arcane-dispatch/device-name` or
  /// the host's `ComputerName`. UI-only.
  final String deviceName;

  /// IP literal (v4 or v6) where the peer's bonded relay is listening.
  final String host;

  /// UDP port the peer is listening on. Defaults to 44430 to match the
  /// reference [speed-server] CLI.
  final int port;

  /// Hex-encoded SHA-256 fingerprint (first 16 hex chars) of the peer's
  /// X25519 static public key. Used to detect MITM swaps without forcing
  /// the user to read 64 hex chars.
  final String fingerprint;

  /// Free-form version string emitted by the peer. Allows future protocol
  /// gating (`requires>=2`) without changing the discovery schema.
  final String version;

  const PairBeacon({
    required this.deviceId,
    required this.deviceName,
    required this.host,
    required this.port,
    required this.fingerprint,
    this.version = '1',
  });

  PairBeacon copyWith({
    String? deviceId,
    String? deviceName,
    String? host,
    int? port,
    String? fingerprint,
    String? version,
  }) {
    return PairBeacon(
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      host: host ?? this.host,
      port: port ?? this.port,
      fingerprint: fingerprint ?? this.fingerprint,
      version: version ?? this.version,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'deviceId': deviceId,
        'deviceName': deviceName,
        'host': host,
        'port': port,
        'fingerprint': fingerprint,
        'version': version,
      };

  factory PairBeacon.fromJson(Map<String, Object?> json) {
    return PairBeacon(
      deviceId: (json['deviceId'] as String?) ?? '',
      deviceName: (json['deviceName'] as String?) ?? 'Unknown',
      host: (json['host'] as String?) ?? '',
      port: (json['port'] is int) ? json['port'] as int : 44430,
      fingerprint: (json['fingerprint'] as String?) ?? '',
      version: (json['version'] as String?) ?? '1',
    );
  }

  @override
  String toString() =>
      'PairBeacon(deviceId=$deviceId, host=$host:$port, fp=${fingerprint.length > 8 ? fingerprint.substring(0, 8) : fingerprint})';
}

/// Difference event for a [PairDiscovery] stream. Subscribers maintain
/// their own map keyed by `beacon.deviceId`.
class PairBeaconEvent {
  final PairBeacon beacon;
  final PairBeaconEventType type;
  const PairBeaconEvent.found(this.beacon) : type = PairBeaconEventType.found;
  const PairBeaconEvent.lost(this.beacon) : type = PairBeaconEventType.lost;
}

enum PairBeaconEventType { found, lost }

/// Discovery surface. Implementations:
///
/// * `BonjourPairDiscovery` (Phase 13 production, Swift bridge): publishes
///   and browses `_arcane-dispatch._tcp` on every interface, returns a
///   coalesced stream.
/// * `LoopbackPairDiscovery` (Phase 13 tests + Local Mode dev): keeps an
///   in-memory registry; multiple instances see each other directly.
///
/// The interface is intentionally minimal so we can swap in a WebSocket
/// rendezvous (Phase 16) for WAN pairing without changing call sites.
abstract class PairDiscovery {
  /// All peers currently visible. The very first listen replays the cache.
  Stream<PairBeaconEvent> watch();

  /// Snapshot of currently-known peers.
  List<PairBeacon> get current;

  /// Publish ourselves so other instances can find us. Returns once the
  /// advertisement is live (or queued, for fake transports).
  Future<void> publish(PairBeacon self);

  /// Stop publishing. Idempotent.
  Future<void> unpublish();

  /// Free all resources. Multiple calls are safe.
  Future<void> dispose();
}

/// In-memory discovery used by tests and Local Mode previews. Two
/// instances sharing the same [LoopbackPairRegistry] see each other.
class LoopbackPairDiscovery implements PairDiscovery {
  final LoopbackPairRegistry _registry;
  final StreamController<PairBeaconEvent> _events =
      StreamController<PairBeaconEvent>.broadcast();
  PairBeacon? _self;
  late final StreamSubscription<PairBeaconEvent> _bridge;
  bool _disposed = false;

  LoopbackPairDiscovery(this._registry) {
    _bridge = _registry.events.listen(_onRegistry);
  }

  void _onRegistry(PairBeaconEvent event) {
    if (_self != null && event.beacon.deviceId == _self!.deviceId) {
      // Don't echo our own beacons back to ourselves.
      return;
    }
    _events.add(event);
  }

  @override
  Stream<PairBeaconEvent> watch() async* {
    for (PairBeacon b in _registry.snapshot()) {
      if (_self != null && b.deviceId == _self!.deviceId) {
        continue;
      }
      yield PairBeaconEvent.found(b);
    }
    yield* _events.stream;
  }

  @override
  List<PairBeacon> get current {
    if (_self == null) {
      return _registry.snapshot();
    }
    return _registry
        .snapshot()
        .where((PairBeacon b) => b.deviceId != _self!.deviceId)
        .toList(growable: false);
  }

  @override
  Future<void> publish(PairBeacon self) async {
    _self = self;
    _registry.register(self);
  }

  @override
  Future<void> unpublish() async {
    if (_self != null) {
      _registry.unregister(_self!.deviceId);
      _self = null;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await unpublish();
    await _bridge.cancel();
    await _events.close();
  }
}

/// Shared backing store for [LoopbackPairDiscovery] instances. Real
/// production code uses the OS's mDNS responder; tests/local mode use
/// this in-memory bus.
class LoopbackPairRegistry {
  final Map<String, PairBeacon> _peers = <String, PairBeacon>{};
  final StreamController<PairBeaconEvent> _events =
      StreamController<PairBeaconEvent>.broadcast();

  Stream<PairBeaconEvent> get events => _events.stream;

  List<PairBeacon> snapshot() => List<PairBeacon>.unmodifiable(_peers.values);

  void register(PairBeacon beacon) {
    PairBeacon? previous = _peers[beacon.deviceId];
    _peers[beacon.deviceId] = beacon;
    if (previous == null) {
      _events.add(PairBeaconEvent.found(beacon));
    } else if (previous.host != beacon.host || previous.port != beacon.port) {
      // Treat host/port churn as a re-found event so subscribers update.
      _events.add(PairBeaconEvent.found(beacon));
    }
  }

  void unregister(String deviceId) {
    PairBeacon? removed = _peers.remove(deviceId);
    if (removed != null) {
      _events.add(PairBeaconEvent.lost(removed));
    }
  }

  Future<void> dispose() async {
    _peers.clear();
    await _events.close();
  }
}
