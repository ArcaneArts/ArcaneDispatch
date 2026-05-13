import 'dart:convert';

import 'bonding_mode.dart';
import 'link.dart';

/// Top-level user intent for the bonded transport.
///
/// A [Policy] is the single source of truth that gets written to the App
/// Group's `policy.json` and read by both the Dart UI and the Network
/// Extension. All fields are pure data (no callbacks, no IO) so the policy
/// can be safely serialized, diffed, and applied atomically.
class Policy {
  /// Wire-schema version. Bumped only when the JSON layout changes in a
  /// breaking way that requires extension/server upgrades. The current schema
  /// is documented in `docs/policy_schema.json`.
  static const int schemaVersion = 1;

  /// Active bonding mode. See [BondingMode] for semantics.
  final BondingMode mode;

  /// All configured links in user-defined order. UI ordering and dispatcher
  /// ordering both consume this list as-is.
  final List<Link> links;

  /// When true, the transport blocks egress whenever the supervisor reports
  /// no healthy link. When false, traffic is allowed to leak to the kernel's
  /// default route during outages.
  final bool killSwitch;

  /// DNS servers pushed by the tunnel (`tun` settings). Empty falls back to
  /// system defaults.
  final List<String> dnsServers;

  /// Apps / hostnames that bypass the tunnel. Implemented as suffix match in
  /// the extension. Empty = everything goes through the tunnel.
  final List<String> splitTunnelAllowList;

  /// Relay URL (e.g. `udp://relay.example.com:4430`). `null` means no relay
  /// is configured yet.
  final String? serverUrl;

  /// Opaque per-client auth token (issued by the server's `genkey`/`adduser`
  /// commands). Stored in the App Group for the extension to read.
  final String? serverToken;

  /// When true, the macOS Network Extension sends packet flow through
  /// the relay-backed bonded transport.
  final bool bondedTransport;

  /// When true, each link runs a recurring HTTP probe against Apple's
  /// captive-portal endpoint (or any equivalent target). Links that come
  /// back as `captive` are effectively demoted to `Backup` priority by
  /// the controller's policy view until they pass again.
  ///
  /// Defaults to **on**: this is the only mechanism we have to detect
  /// "connected but no internet" (coffee-shop Wi-Fi waiting on a ToS
  /// login). Without it, a captive link looks healthy to the supervisor
  /// (its TCP probe completes against the portal's transparent proxy)
  /// and traffic silently fails. Users can still flip it off in
  /// `Mode > Help me sign in to coffee-shop Wi-Fi`.
  final bool captivePortalAssist;

  const Policy({
    this.mode = BondingMode.speed,
    this.links = const <Link>[],
    this.killSwitch = false,
    this.dnsServers = const <String>[],
    this.splitTunnelAllowList = const <String>[],
    this.serverUrl,
    this.serverToken,
    this.bondedTransport = false,
    this.captivePortalAssist = true,
  });

  Policy copyWith({
    BondingMode? mode,
    List<Link>? links,
    bool? killSwitch,
    List<String>? dnsServers,
    List<String>? splitTunnelAllowList,
    Object? serverUrl = _sentinel,
    Object? serverToken = _sentinel,
    bool? bondedTransport,
    bool? captivePortalAssist,
  }) {
    return Policy(
      mode: mode ?? this.mode,
      links: links ?? this.links,
      killSwitch: killSwitch ?? this.killSwitch,
      dnsServers: dnsServers ?? this.dnsServers,
      splitTunnelAllowList: splitTunnelAllowList ?? this.splitTunnelAllowList,
      serverUrl: identical(serverUrl, _sentinel)
          ? this.serverUrl
          : serverUrl as String?,
      serverToken: identical(serverToken, _sentinel)
          ? this.serverToken
          : serverToken as String?,
      bondedTransport: bondedTransport ?? this.bondedTransport,
      captivePortalAssist: captivePortalAssist ?? this.captivePortalAssist,
    );
  }

  /// Convenience: returns the link with the given id or `null`.
  Link? linkById(String id) {
    for (Link link in links) {
      if (link.id == id) {
        return link;
      }
    }
    return null;
  }

  /// Returns a copy of [links] grouped by [LinkPriority] in priority order
  /// (primary first, never last). Within a group, original order is kept.
  Map<LinkPriority, List<Link>> linksByPriority() {
    Map<LinkPriority, List<Link>> result = <LinkPriority, List<Link>>{
      for (LinkPriority p in LinkPriority.values) p: <Link>[],
    };
    for (Link link in links) {
      result[link.priority]!.add(link);
    }
    return result;
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'version': schemaVersion,
      'mode': mode.wireName,
      'links': links.map((Link link) => link.toJson()).toList(),
      'killSwitch': killSwitch,
      'dnsServers': dnsServers,
      'splitTunnelAllowList': splitTunnelAllowList,
      'serverUrl': serverUrl,
      'serverToken': serverToken,
      'bondedTransport': bondedTransport,
      'captivePortalAssist': captivePortalAssist,
    };
  }

  factory Policy.fromJson(Map<String, Object?> json) {
    List<Link> links = <Link>[];
    Object? rawLinks = json['links'];
    if (rawLinks is List) {
      for (Object? entry in rawLinks) {
        if (entry is Map<String, Object?>) {
          links.add(Link.fromJson(entry));
        } else if (entry is Map) {
          links.add(Link.fromJson(entry.cast<String, Object?>()));
        }
      }
    }
    return Policy(
      mode: BondingModeCodec.parse(json['mode']),
      links: links,
      killSwitch: _coerceBool(json['killSwitch'], fallback: false),
      dnsServers: _coerceStringList(json['dnsServers']),
      splitTunnelAllowList: _coerceStringList(json['splitTunnelAllowList']),
      serverUrl: json['serverUrl'] as String?,
      serverToken: json['serverToken'] as String?,
      bondedTransport: _coerceBool(json['bondedTransport'], fallback: false),
      captivePortalAssist: _coerceBool(
        json['captivePortalAssist'],
        fallback: true,
      ),
    );
  }

  String encode() {
    return jsonEncode(toJson());
  }

  static Policy decode(String source) {
    Object? raw = jsonDecode(source);
    if (raw is Map<String, Object?>) {
      return Policy.fromJson(raw);
    }
    if (raw is Map) {
      return Policy.fromJson(raw.cast<String, Object?>());
    }
    throw FormatException('Policy payload is not a JSON object: $source');
  }

  static bool _coerceBool(Object? value, {required bool fallback}) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    if (value is String) {
      String normalized = value.toLowerCase();
      if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
        return true;
      }
      if (normalized == 'false' || normalized == '0' || normalized == 'no') {
        return false;
      }
    }
    return fallback;
  }

  static List<String> _coerceStringList(Object? value) {
    if (value is List) {
      return value
          .where((Object? element) => element != null)
          .map((Object? element) => element.toString())
          .toList();
    }
    return const <String>[];
  }
}

const Object _sentinel = Object();
