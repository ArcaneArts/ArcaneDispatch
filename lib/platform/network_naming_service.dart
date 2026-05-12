import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Coarse interface kind, mirrors `NamedKind` in
/// `macos/Runner/NetworkNamingHandler.swift`. Used to pick UI icons and to
/// sort the network list into sensible buckets.
enum NamedInterfaceKind {
  wifi,
  ethernet,
  cellularTether,
  bluetoothTether,
  thunderbolt,
  loopback,
  virtualTunnel,
  bridge,
  other,
}

extension NamedInterfaceKindWire on NamedInterfaceKind {
  /// Wire name matching the Swift enum's `rawValue`. Keep in sync.
  String get wireName {
    switch (this) {
      case NamedInterfaceKind.wifi:
        return 'wifi';
      case NamedInterfaceKind.ethernet:
        return 'ethernet';
      case NamedInterfaceKind.cellularTether:
        return 'cellularTether';
      case NamedInterfaceKind.bluetoothTether:
        return 'bluetoothTether';
      case NamedInterfaceKind.thunderbolt:
        return 'thunderbolt';
      case NamedInterfaceKind.loopback:
        return 'loopback';
      case NamedInterfaceKind.virtualTunnel:
        return 'virtualTunnel';
      case NamedInterfaceKind.bridge:
        return 'bridge';
      case NamedInterfaceKind.other:
        return 'other';
    }
  }

  static NamedInterfaceKind parse(Object? value) {
    if (value is String) {
      for (NamedInterfaceKind k in NamedInterfaceKind.values) {
        if (k.wireName == value) return k;
      }
    }
    return NamedInterfaceKind.other;
  }
}

/// One macOS hardware port, named.
///
/// Carries everything we know about a single network interface that's
/// useful to a *user*. The raw BSD device name (`en0`, `en7`, `pdp_ip0`)
/// is preserved in [bsdName] so internal callers can still match against
/// the existing [NetworkInterfaceSnapshot] entries; everything else is
/// presentation candy.
class NamedInterface {
  /// BSD device name (`en0`, `en7`). Always present; used as the join key.
  final String bsdName;

  /// macOS "Hardware Port" name (`Wi-Fi`, `USB 10/100/1000 LAN`,
  /// `iPhone USB`, `Bluetooth PAN`). May be empty for synthetic ports the
  /// resolver couldn't classify.
  final String hardwarePort;

  /// SSID currently associated with this Wi-Fi interface. `null` for
  /// non-Wi-Fi interfaces or when disconnected.
  final String? ssid;

  /// Hardware MAC, lower-case colon-separated. `null` when macOS reports
  /// `n/a` (virtual interfaces).
  final String? macAddress;

  /// Coarse classification used for icons / sorting.
  final NamedInterfaceKind kind;

  const NamedInterface({
    required this.bsdName,
    this.hardwarePort = '',
    this.ssid,
    this.macAddress,
    this.kind = NamedInterfaceKind.other,
  });

  /// Human label preferred order:
  /// 1. SSID for Wi-Fi (the network name the user knows).
  /// 2. Hardware port name (`iPhone USB`, `USB 10/100/1000 LAN`).
  /// 3. BSD device name as a last resort.
  String get displayName {
    if (ssid != null && ssid!.isNotEmpty) return ssid!;
    if (hardwarePort.isNotEmpty) return hardwarePort;
    return bsdName;
  }

  /// Short kind label for chips (`Wi-Fi`, `Ethernet`, `Cellular`, …).
  String get kindLabel {
    switch (kind) {
      case NamedInterfaceKind.wifi:
        return 'Wi-Fi';
      case NamedInterfaceKind.ethernet:
        return 'Ethernet';
      case NamedInterfaceKind.cellularTether:
        return 'Cellular';
      case NamedInterfaceKind.bluetoothTether:
        return 'Bluetooth';
      case NamedInterfaceKind.thunderbolt:
        return 'Thunderbolt';
      case NamedInterfaceKind.loopback:
        return 'Loopback';
      case NamedInterfaceKind.virtualTunnel:
        return 'VPN';
      case NamedInterfaceKind.bridge:
        return 'Bridge';
      case NamedInterfaceKind.other:
        return hardwarePort.isEmpty ? 'Network' : hardwarePort;
    }
  }

  /// True iff this interface is the sort of thing a normal user would
  /// expect to see in a network picker. Filters out internal Apple
  /// plumbing (`awdl0`, `bridge0`, virtual tunnels) so the UX list stays
  /// short and meaningful.
  bool get isUserFacing {
    switch (kind) {
      case NamedInterfaceKind.wifi:
      case NamedInterfaceKind.ethernet:
      case NamedInterfaceKind.cellularTether:
      case NamedInterfaceKind.bluetoothTether:
      case NamedInterfaceKind.thunderbolt:
        return true;
      case NamedInterfaceKind.bridge:
      case NamedInterfaceKind.virtualTunnel:
      case NamedInterfaceKind.loopback:
      case NamedInterfaceKind.other:
        return false;
    }
  }

  /// Construct from the channel's raw `Map`. Returns null when the payload
  /// is missing a usable [bsdName].
  static NamedInterface? fromChannel(Object? value) {
    if (value is! Map) return null;
    Object? rawBsd = value['bsdName'];
    if (rawBsd is! String || rawBsd.isEmpty) return null;
    return NamedInterface(
      bsdName: rawBsd,
      hardwarePort: (value['hardwarePort'] as String?) ?? '',
      ssid: value['ssid'] as String?,
      macAddress: value['macAddress'] as String?,
      kind: NamedInterfaceKindWire.parse(value['kind']),
    );
  }

  NamedInterface copyWith({String? ssid, String? hardwarePort}) {
    return NamedInterface(
      bsdName: bsdName,
      hardwarePort: hardwarePort ?? this.hardwarePort,
      ssid: ssid ?? this.ssid,
      macAddress: macAddress,
      kind: kind,
    );
  }
}

/// Optional injection point for tests so we don't have to spin up a real
/// MethodChannel handler. Production wires the macOS handler via
/// `MainFlutterWindow.swift`.
typedef NamedInterfaceFetcher = Future<List<NamedInterface>> Function();

/// Periodically reads the friendly per-interface metadata from the macOS
/// side and exposes it as a [ChangeNotifier]. The UI listens and rebuilds
/// to swap raw `en0` strings for "Home Wi-Fi" / "iPhone USB" / etc.
///
/// Why a service instead of one-shot lookups: SSIDs change frequently
/// (Wi-Fi roam) and `networksetup` shells take ~30 ms each — calling them
/// per build would jank the UI. Refreshing every few seconds is cheap and
/// keeps everything in lockstep with reality.
class NetworkNamingService extends ChangeNotifier {
  /// Channel name. Must mirror the Swift handler.
  static const MethodChannel _channel =
      MethodChannel('art.arcane.dispatch/naming');

  final NamedInterfaceFetcher _fetch;
  final Duration _refreshInterval;
  final bool _autoStart;

  Map<String, NamedInterface> _byBsd = const <String, NamedInterface>{};
  Timer? _timer;
  bool _disposed = false;
  bool _refreshing = false;

  /// [fetcher] overrides the default channel-based resolver. Tests pass a
  /// fake to avoid MethodChannel setup.
  ///
  /// [autoStart] (default true in production) controls whether [start]
  /// actually arms the periodic timer. Tests can set it to `false` to
  /// keep the service inert — the cache stays empty, no timers leak, and
  /// every call still works for read access. Production wiring (the
  /// `MainFlutterWindow.swift` channel) always uses the default.
  NetworkNamingService({
    NamedInterfaceFetcher? fetcher,
    Duration refreshInterval = const Duration(seconds: 6),
    bool autoStart = true,
  })  : _fetch = fetcher ?? _defaultFetcher,
        _refreshInterval = refreshInterval,
        _autoStart = autoStart;

  /// Read-only snapshot. Returns an empty map until the first refresh
  /// completes. UI must not assume a specific key set is present.
  Map<String, NamedInterface> get byBsd {
    return _byBsd;
  }

  /// Resolve a single BSD device name. Returns `null` when the resolver
  /// hasn't seen that device yet or the OS doesn't expose it.
  NamedInterface? lookup(String bsdName) {
    return _byBsd[bsdName];
  }

  /// Begin periodic refresh. Idempotent — calling twice is harmless.
  /// Drives an immediate refresh so the UI gets first names quickly.
  ///
  /// Becomes a no-op when [autoStart] was set to `false` on construction
  /// (test mode). Callers can still drive the cache manually via
  /// [refresh].
  void start() {
    if (_disposed) return;
    if (!_autoStart) return;
    if (_timer != null) return;
    _timer = Timer.periodic(_refreshInterval, (_) {
      unawaited(refresh());
    });
    unawaited(refresh());
  }

  /// Stop the periodic refresh. The current snapshot stays available.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Force a one-shot refresh. Safe to call from anywhere; deduplicates
  /// concurrent calls so a manual UI refresh during a Timer tick doesn't
  /// run the resolver twice.
  Future<void> refresh() async {
    if (_disposed || _refreshing) return;
    _refreshing = true;
    try {
      List<NamedInterface> items = await _fetch();
      if (_disposed) return;
      Map<String, NamedInterface> next = <String, NamedInterface>{};
      for (NamedInterface item in items) {
        next[item.bsdName] = item;
      }
      if (!_mapEquals(_byBsd, next)) {
        _byBsd = Map<String, NamedInterface>.unmodifiable(next);
        notifyListeners();
      }
    } catch (_) {
      // Channel not available (tests, non-macOS) or shell failed —
      // keep the last-known cache instead of clearing it.
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    super.dispose();
  }

  bool _mapEquals(
      Map<String, NamedInterface> a, Map<String, NamedInterface> b) {
    if (a.length != b.length) return false;
    for (MapEntry<String, NamedInterface> e in a.entries) {
      NamedInterface? other = b[e.key];
      if (other == null) return false;
      if (other.ssid != e.value.ssid) return false;
      if (other.hardwarePort != e.value.hardwarePort) return false;
      if (other.kind != e.value.kind) return false;
    }
    return true;
  }

  /// Default fetcher: drives the `art.arcane.dispatch/naming` channel.
  /// Returns an empty list when the channel isn't implemented (other
  /// platforms, tests without a binary messenger).
  static Future<List<NamedInterface>> _defaultFetcher() async {
    try {
      Object? raw = await _channel.invokeMethod('list');
      if (raw is List) {
        List<NamedInterface> out = <NamedInterface>[];
        for (Object? item in raw) {
          NamedInterface? parsed = NamedInterface.fromChannel(item);
          if (parsed != null) out.add(parsed);
        }
        return out;
      }
    } on MissingPluginException {
      // Naming plugin not wired (e.g. integration test running on Linux).
    } on PlatformException {
      // Handler raised on the Swift side. Swallow — keep last-known.
    }
    return const <NamedInterface>[];
  }
}
