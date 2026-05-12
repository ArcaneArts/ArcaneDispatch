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
  /// 1. For Wi-Fi: `Wi-Fi — SSID` so the user sees both the connection
  ///    kind and the network they're on (e.g. `Wi-Fi — Hometown`).
  ///    Falls back to just the SSID if `kind` somehow isn't `wifi`.
  /// 2. Hardware port name (`iPhone USB`, `USB 10/100/1000 LAN`).
  /// 3. BSD device name as a last resort.
  String get displayName {
    if (ssid != null && ssid!.isNotEmpty) {
      return kind == NamedInterfaceKind.wifi ? 'Wi-Fi \u2014 ${ssid!}' : ssid!;
    }
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

/// One saved network service as System Settings → Network displays it.
///
/// Unlike [NamedInterface] (which only enumerates currently-attached
/// hardware ports), a [KnownNetworkService] is something the OS *knows
/// about* — including ports that aren't currently up. Examples:
///
///   * `iPhone USB` (en8) — the user has tethered their iPhone via USB
///     before; the service is saved, but `en8` only comes up when the
///     iPhone is plugged in.
///   * `USB 10/100/1000 LAN` (en10) — a USB-Ethernet adapter the user
///     has paired with before; the service is saved, but `en10` only
///     comes up when the adapter is plugged in.
///   * `Bluetooth PAN` — surfaces when there's a paired
///     Bluetooth-tether-capable device.
///
/// Surfacing these lets the user *know* that Dispatch will combine
/// their iPhone tether the moment they plug it in, instead of having to
/// guess whether it's even being considered.
class KnownNetworkService {
  /// User-visible service name from `networksetup -listnetworkserviceorder`
  /// (`Wi-Fi`, `iPhone USB`, `USB 10/100/1000 LAN 2`).
  final String serviceName;

  /// Hardware-port name as macOS exposes it. Identical to [serviceName]
  /// for most entries; differs only when the user renamed the service
  /// in System Settings.
  final String hardwarePort;

  /// BSD device name (`en0`, `en8`, …). Null when the service has no
  /// underlying device — pure-virtual VPN services (already filtered out
  /// on the Swift side, but defensively kept nullable here).
  final String? bsdName;

  /// SSID currently associated with this interface — only populated for
  /// Wi-Fi entries that are currently up.
  final String? ssid;

  /// Coarse kind classification, same vocabulary as [NamedInterfaceKind].
  final NamedInterfaceKind kind;

  /// True iff the BSD device is currently up (`ifconfig -lu`). The UI
  /// uses this to bucket entries into Connected / Disconnected /
  /// Available.
  final bool isCurrentlyAvailable;

  /// True iff the service is starred in `networksetup`'s listing — the
  /// user has explicitly turned it off in System Settings → Network.
  /// We still surface it (greyed out) so the user can see it.
  final bool disabled;

  const KnownNetworkService({
    required this.serviceName,
    required this.hardwarePort,
    required this.kind,
    this.bsdName,
    this.ssid,
    this.isCurrentlyAvailable = false,
    this.disabled = false,
  });

  /// Human-friendly display label.
  /// 1. For Wi-Fi: `Wi-Fi — SSID` so the kind is always obvious even
  ///    when the SSID is something cute like `Hometown`. Falls back to
  ///    just the SSID if `kind` somehow isn't `wifi`.
  /// 2. The service name otherwise — that's the name the user gave it
  ///    in System Settings.
  String get displayName {
    if (ssid != null && ssid!.isNotEmpty) {
      return kind == NamedInterfaceKind.wifi ? 'Wi-Fi \u2014 ${ssid!}' : ssid!;
    }
    return serviceName.isEmpty ? hardwarePort : serviceName;
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

  /// True iff this service is one a normal user would expect to see in
  /// a network picker (Wi-Fi, Ethernet, cellular/bluetooth tether,
  /// Thunderbolt). Bridges and loopback are filtered out.
  ///
  /// We're intentionally permissive about `.other`: many USB-Ethernet
  /// adapters report a chipset name (e.g. `AX88179A`) that our keyword
  /// classifier can't bucket, but the user explicitly added them as a
  /// network service so we still surface them. Truly internal entries
  /// (bridges, loopback, VPN passthrough) are excluded.
  bool get isUserFacing {
    switch (kind) {
      case NamedInterfaceKind.wifi:
      case NamedInterfaceKind.ethernet:
      case NamedInterfaceKind.cellularTether:
      case NamedInterfaceKind.bluetoothTether:
      case NamedInterfaceKind.thunderbolt:
        return true;
      case NamedInterfaceKind.other:
        // Surface saved services that have a real hardware device. The
        // user put them there; we trust the user.
        return bsdName != null && bsdName!.isNotEmpty;
      case NamedInterfaceKind.bridge:
      case NamedInterfaceKind.virtualTunnel:
      case NamedInterfaceKind.loopback:
        return false;
    }
  }

  /// Parse one channel payload. Returns null on missing keys.
  static KnownNetworkService? fromChannel(Object? value) {
    if (value is! Map) return null;
    Object? rawName = value['serviceName'];
    if (rawName is! String || rawName.isEmpty) return null;
    return KnownNetworkService(
      serviceName: rawName,
      hardwarePort: (value['hardwarePort'] as String?) ?? rawName,
      bsdName: value['bsdName'] as String?,
      ssid: value['ssid'] as String?,
      kind: NamedInterfaceKindWire.parse(value['kind']),
      isCurrentlyAvailable: value['isCurrentlyAvailable'] == true,
      disabled: value['disabled'] == true,
    );
  }
}

/// Optional injection point for tests so we don't have to spin up a real
/// MethodChannel handler. Production wires the macOS handler via
/// `MainFlutterWindow.swift`.
typedef NamedInterfaceFetcher = Future<List<NamedInterface>> Function();

/// Same idea but for [KnownNetworkService]s — refreshes the saved
/// network-services list. Tests pass a fake to avoid MethodChannel
/// setup.
typedef KnownServiceFetcher = Future<List<KnownNetworkService>> Function();

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
  final KnownServiceFetcher _fetchServices;
  final Duration _refreshInterval;
  final bool _autoStart;

  Map<String, NamedInterface> _byBsd = const <String, NamedInterface>{};
  List<KnownNetworkService> _services = const <KnownNetworkService>[];
  Timer? _timer;
  bool _disposed = false;
  bool _refreshing = false;

  /// [fetcher] overrides the default channel-based resolver. Tests pass a
  /// fake to avoid MethodChannel setup. [servicesFetcher] does the same
  /// for the saved-network-services list.
  ///
  /// [autoStart] (default true in production) controls whether [start]
  /// actually arms the periodic timer. Tests can set it to `false` to
  /// keep the service inert — the cache stays empty, no timers leak, and
  /// every call still works for read access. Production wiring (the
  /// `MainFlutterWindow.swift` channel) always uses the default.
  NetworkNamingService({
    NamedInterfaceFetcher? fetcher,
    KnownServiceFetcher? servicesFetcher,
    Duration refreshInterval = const Duration(seconds: 6),
    bool autoStart = true,
  })  : _fetch = fetcher ?? _defaultFetcher,
        _fetchServices = servicesFetcher ?? _defaultServicesFetcher,
        _refreshInterval = refreshInterval,
        _autoStart = autoStart;

  /// Read-only snapshot. Returns an empty map until the first refresh
  /// completes. UI must not assume a specific key set is present.
  Map<String, NamedInterface> get byBsd {
    return _byBsd;
  }

  /// Saved network services as System Settings → Network lists them.
  /// Returns an empty list until the first refresh; refreshes in lockstep
  /// with [byBsd].
  List<KnownNetworkService> get services {
    return _services;
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
      // Fetch interfaces + saved services concurrently; the calls are
      // independent.
      List<dynamic> results = await Future.wait(<Future<dynamic>>[
        _fetch(),
        _fetchServices(),
      ]);
      if (_disposed) return;
      List<NamedInterface> items = results[0] as List<NamedInterface>;
      List<KnownNetworkService> svcItems =
          results[1] as List<KnownNetworkService>;
      Map<String, NamedInterface> next = <String, NamedInterface>{};
      for (NamedInterface item in items) {
        next[item.bsdName] = item;
      }
      bool changed = false;
      if (!_mapEquals(_byBsd, next)) {
        _byBsd = Map<String, NamedInterface>.unmodifiable(next);
        changed = true;
      }
      if (!_servicesEquals(_services, svcItems)) {
        _services = List<KnownNetworkService>.unmodifiable(svcItems);
        changed = true;
      }
      if (changed) {
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

  bool _servicesEquals(
      List<KnownNetworkService> a, List<KnownNetworkService> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      KnownNetworkService x = a[i];
      KnownNetworkService y = b[i];
      if (x.serviceName != y.serviceName) return false;
      if (x.hardwarePort != y.hardwarePort) return false;
      if (x.bsdName != y.bsdName) return false;
      if (x.ssid != y.ssid) return false;
      if (x.kind != y.kind) return false;
      if (x.isCurrentlyAvailable != y.isCurrentlyAvailable) return false;
      if (x.disabled != y.disabled) return false;
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

  /// Default fetcher for saved network services.
  static Future<List<KnownNetworkService>> _defaultServicesFetcher() async {
    try {
      Object? raw = await _channel.invokeMethod('listKnownServices');
      if (raw is List) {
        List<KnownNetworkService> out = <KnownNetworkService>[];
        for (Object? item in raw) {
          KnownNetworkService? parsed = KnownNetworkService.fromChannel(item);
          if (parsed != null) out.add(parsed);
        }
        return out;
      }
    } on MissingPluginException {
      // Naming plugin not wired (older app version, non-macOS, test
      // without a messenger). Return empty so the UI just falls back to
      // what it had before — the live interfaces list.
    } on PlatformException {
      // Swift handler raised. Swallow — keep last-known.
    }
    return const <KnownNetworkService>[];
  }
}
