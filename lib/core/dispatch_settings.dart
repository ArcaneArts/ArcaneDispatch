import 'package:hive/hive.dart';

import 'link.dart';
import 'policy.dart';
import '../transport/transport.dart';

/// Persisted user settings.
///
/// Phase 1 schema (`links_v1`):
///
/// * `listen_host` / `listen_port` — legacy SOCKS endpoint config.
/// * `launch_at_startup` / `start_on_launch` / `hide_on_blur` — UX flags.
/// * `selected_targets` — legacy `<target>[/weight]` list. Kept readable for
///   one release window so a user can roll back to a pre-`links_v1` build
///   without losing their interface picks.
/// * `links_v1` — JSON-encoded list of [Link]s. New schema. Source of truth.
/// * `policy_v1` — JSON-encoded [Policy] (mode, killSwitch, dns, etc.).
/// * `transport_kind` — `socks` (default) or `tunnel`.
///
/// Migration runs in [load]: when `links_v1` is missing but `selected_targets`
/// exists, we synthesize a [Link] per legacy token (`Link.fromLegacyTarget`)
/// and write it back under `links_v1`. The legacy key stays in place so a
/// downgrade still works.
class DispatchSettings {
  /// Current persistent schema version. Bumped if [load] needs to do anything
  /// destructive in the future (Phase 1 stays at 1).
  static const int schemaVersion = 1;
  static const String defaultRelayUrl = String.fromEnvironment(
    'ARCANE_DISPATCH_RELAY_URL',
    defaultValue: 'udp://slc01.qualitynode.com:7777',
  );
  static const String defaultRelayToken = String.fromEnvironment(
    'ARCANE_DISPATCH_RELAY_TOKEN',
    defaultValue: 'lgnzpJXxSCTr_Xq2Jn_LrEEQQiD1UGnttOqeqePYaKQ',
  );
  static const Policy defaultPolicy = Policy(
    serverUrl: defaultRelayUrl,
    serverToken: defaultRelayToken,
    bondedTransport: true,
  );

  static const String _legacyTargetsKey = 'selected_targets';
  static const String _linksKey = 'links_v1';
  static const String _policyKey = 'policy_v1';
  static const String _transportKindKey = 'transport_kind';
  static const String _schemaVersionKey = 'schema_version';

  final String listenHost;
  final int listenPort;
  final bool launchAtStartup;
  final bool startProxyOnLaunch;
  final bool hideOnBlur;
  final TransportKind transportKind;
  final List<Link> links;
  final Policy policy;

  const DispatchSettings({
    this.listenHost = '127.0.0.1',
    this.listenPort = 1080,
    this.launchAtStartup = false,
    this.startProxyOnLaunch = false,
    this.hideOnBlur = true,
    // Tunnel mode (system-wide Network Extension) is the default because
    // that's the experience the product is meant to replace — Speedify
    // covers every app on the machine without per-app configuration.
    // SOCKS is still available from the gear-icon settings for power
    // users who want a per-app proxy or who don't have the Network
    // Extension entitlement signed in to their build.
    this.transportKind = TransportKind.tunnel,
    this.links = const <Link>[],
    this.policy = defaultPolicy,
  });

  /// Legacy view of the selected targets, kept so existing UI code that still
  /// renders `<target>[/weight]` chips keeps working until Phase 15 replaces
  /// it. Derived from [links] on the fly so it never goes stale.
  List<String> get selectedTargets {
    return links
        .where((Link link) => link.priority != LinkPriority.never)
        .map((Link link) => link.toLegacyTarget())
        .toList();
  }

  DispatchSettings copyWith({
    String? listenHost,
    int? listenPort,
    bool? launchAtStartup,
    bool? startProxyOnLaunch,
    bool? hideOnBlur,
    TransportKind? transportKind,
    List<Link>? links,
    Policy? policy,
  }) {
    return DispatchSettings(
      listenHost: listenHost ?? this.listenHost,
      listenPort: listenPort ?? this.listenPort,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      startProxyOnLaunch: startProxyOnLaunch ?? this.startProxyOnLaunch,
      hideOnBlur: hideOnBlur ?? this.hideOnBlur,
      transportKind: transportKind ?? this.transportKind,
      links: links ?? this.links,
      policy: policy ?? this.policy,
    );
  }

  /// Convenience overload: replace the legacy target list, regenerating the
  /// underlying [links]. Used by the existing checkbox UI in [home_screen].
  DispatchSettings copyWithSelectedTargets(List<String> targets) {
    List<Link> next = _buildLinksFromTargets(targets, existing: links);
    return copyWith(
      links: next,
      policy: policy.copyWith(links: next),
    );
  }

  static DispatchSettings load(Box box) {
    List<Link> links = _readLinks(box);
    Policy policy = _readPolicy(box, links);

    return DispatchSettings(
      listenHost: box.get('listen_host', defaultValue: '127.0.0.1').toString(),
      listenPort: _coercePort(box.get('listen_port'), fallback: 1080),
      launchAtStartup:
          box.get('launch_at_startup', defaultValue: false) == true,
      startProxyOnLaunch: false,
      hideOnBlur: box.get('hide_on_blur', defaultValue: true) == true,
      transportKind: TransportKindCodec.parse(box.get(_transportKindKey)),
      links: links,
      policy: policy,
    );
  }

  Future<void> save(Box box) async {
    Policy relayPolicy = withDefaultRelay(policy, links: links);
    await box.put('listen_host', listenHost);
    await box.put('listen_port', listenPort);
    await box.put('launch_at_startup', launchAtStartup);
    await box.put('start_proxy_on_launch', false);
    await box.put('hide_on_blur', hideOnBlur);
    await box.put(_transportKindKey, transportKind.wireName);
    await box.put(_linksKey, links.map((Link link) => link.encode()).toList());
    await box.put(_policyKey, relayPolicy.encode());
    // Mirror to the legacy key so a downgrade keeps the user's picks.
    await box.put(_legacyTargetsKey, selectedTargets);
    await box.put(_schemaVersionKey, schemaVersion);
  }

  static List<Link> _readLinks(Box box) {
    Object? raw = box.get(_linksKey);
    if (raw is List) {
      List<Link> result = <Link>[];
      for (Object? entry in raw) {
        try {
          if (entry is String) {
            result.add(Link.decode(entry));
          } else if (entry is Map) {
            result.add(Link.fromJson(entry.cast<String, Object?>()));
          }
        } catch (_) {
          // Skip malformed entries — they will be regenerated from the legacy
          // list below if present.
        }
      }
      if (result.isNotEmpty) {
        return result;
      }
    }

    // Migration path: synthesize Link objects from the legacy target list.
    List<String> legacy = _readLegacyTargets(box);
    return _buildLinksFromTargets(legacy);
  }

  static Policy _readPolicy(Box box, List<Link> links) {
    Object? raw = box.get(_policyKey);
    if (raw is String && raw.isNotEmpty) {
      try {
        Policy stored = Policy.decode(raw);
        return withDefaultRelay(stored, links: links);
      } catch (_) {
        // Fall through to default policy below.
      }
    }
    return withDefaultRelay(defaultPolicy, links: links);
  }

  static Policy withDefaultRelay(Policy policy, {List<Link>? links}) {
    return policy.copyWith(
      links: links ?? policy.links,
      serverUrl: defaultRelayUrl,
      serverToken: defaultRelayToken,
      bondedTransport: true,
    );
  }

  static List<String> _readLegacyTargets(Box box) {
    Object? raw = box.get(_legacyTargetsKey);
    if (raw is List) {
      return raw.map((Object? value) => value.toString()).toList();
    }
    return const <String>[];
  }

  static List<Link> _buildLinksFromTargets(
    List<String> targets, {
    List<Link> existing = const <Link>[],
  }) {
    Map<String, Link> existingById = <String, Link>{
      for (Link link in existing) link.toLegacyTarget(): link,
    };
    List<Link> result = <Link>[];
    Set<String> seen = <String>{};
    for (String token in targets) {
      String trimmed = token.trim();
      if (trimmed.isEmpty || seen.contains(trimmed)) {
        continue;
      }
      seen.add(trimmed);
      Link? carry = existingById[trimmed];
      if (carry != null) {
        result.add(carry);
        continue;
      }
      result.add(Link.fromLegacyTarget(trimmed));
    }
    return result;
  }

  static int _coercePort(Object? value, {required int fallback}) {
    if (value is int && value > 0 && value <= 65535) {
      return value;
    }
    if (value is String) {
      int? parsed = int.tryParse(value);
      if (parsed != null && parsed > 0 && parsed <= 65535) {
        return parsed;
      }
    }
    return fallback;
  }
}
