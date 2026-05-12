import 'dart:async';

import 'package:flutter/services.dart';

import 'pair_beacon.dart';

/// Bridges the Dart `PairDiscovery` abstraction to the Swift
/// `PairedNetworkService` running on the host process.
///
/// Channel contract (kept identical on both sides):
///
///   MethodChannel:  `dispatch_pair`
///     - `publish` (Map): begin advertising. payload mirrors PairBeacon.toJson()
///     - `unpublish` (void)
///     - `startBrowse` (void): turn on the browser. Events arrive on the
///       event channel below.
///     - `stopBrowse` (void)
///     - `snapshot` (void) -> List<Map>: poll the current peer set.
///
///   EventChannel:   `dispatch_pair/events`
///     - emits `{ kind: 'found'|'lost', beacon: Map<...> }`
class PairedMethodChannelDiscovery implements PairDiscovery {
  static const MethodChannel _method = MethodChannel('dispatch_pair');
  static const EventChannel _events = EventChannel('dispatch_pair/events');

  final StreamController<PairBeaconEvent> _ctrl =
      StreamController<PairBeaconEvent>.broadcast();
  StreamSubscription<dynamic>? _hostSub;
  bool _disposed = false;
  PairBeacon? _self;

  PairedMethodChannelDiscovery() {
    _hostSub = _events.receiveBroadcastStream().listen(_onHostEvent);
  }

  void _onHostEvent(Object? raw) {
    if (raw is! Map) return;
    Object? beaconRaw = raw['beacon'];
    if (beaconRaw is! Map) return;
    PairBeacon beacon = PairBeacon.fromJson(beaconRaw.cast<String, Object?>());
    String kind = (raw['kind'] as String?) ?? 'found';
    if (kind == 'lost') {
      _ctrl.add(PairBeaconEvent.lost(beacon));
    } else {
      _ctrl.add(PairBeaconEvent.found(beacon));
    }
  }

  @override
  Stream<PairBeaconEvent> watch() async* {
    List<PairBeacon> seed = await _snapshotFromHost();
    for (PairBeacon b in seed) {
      yield PairBeaconEvent.found(b);
    }
    yield* _ctrl.stream;
  }

  @override
  List<PairBeacon> get current {
    // The host is the source of truth; callers wanting an immediate
    // snapshot should `await watch().first` or call [refresh].
    return const <PairBeacon>[];
  }

  /// Force a refresh of the cached peer set. Useful after a network
  /// transition where mDNS responders may have re-keyed.
  Future<List<PairBeacon>> refresh() => _snapshotFromHost();

  Future<List<PairBeacon>> _snapshotFromHost() async {
    try {
      Object? raw = await _method.invokeMethod<Object?>('snapshot');
      if (raw is! List) return const <PairBeacon>[];
      return raw
          .whereType<Map>()
          .map((Map m) => PairBeacon.fromJson(m.cast<String, Object?>()))
          .where((PairBeacon b) =>
              _self == null || b.deviceId != _self!.deviceId)
          .toList(growable: false);
    } on PlatformException {
      return const <PairBeacon>[];
    } on MissingPluginException {
      // Host channel not wired up (e.g. unit tests). Soft-fail so the
      // app keeps running with discovery disabled.
      return const <PairBeacon>[];
    }
  }

  @override
  Future<void> publish(PairBeacon self) async {
    _self = self;
    try {
      await _method.invokeMethod<void>('publish', self.toJson());
    } on MissingPluginException {
      // No-op in non-host contexts.
    }
  }

  @override
  Future<void> unpublish() async {
    _self = null;
    try {
      await _method.invokeMethod<void>('unpublish');
    } on MissingPluginException {
      // No-op.
    }
  }

  /// Begin browsing on the host side. Idempotent; safe to call before
  /// listeners attach to `watch()`.
  Future<void> startBrowsing() async {
    try {
      await _method.invokeMethod<void>('startBrowse');
    } on MissingPluginException {
      // No-op.
    }
  }

  /// Stop browsing. Subsequent calls to [watch] still receive events
  /// from new browse calls.
  Future<void> stopBrowsing() async {
    try {
      await _method.invokeMethod<void>('stopBrowse');
    } on MissingPluginException {
      // No-op.
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopBrowsing();
    await _hostSub?.cancel();
    _hostSub = null;
    await _ctrl.close();
  }
}
