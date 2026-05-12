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

  /// When true, the streaming detector tags real-time flows (Zoom/WebRTC/SNI
  /// allow-list) and the scheduler upgrades them to the RT queue.
  final bool streamingDetection;

  /// DNS servers pushed by the tunnel (`tun` settings). Empty falls back to
  /// system defaults.
  final List<String> dnsServers;

  /// Apps / hostnames that bypass the tunnel. Implemented as suffix match in
  /// the extension. Empty = everything goes through the tunnel.
  final List<String> splitTunnelAllowList;

  /// Speed Server URL (e.g. `udp://relay.example.com:443`). `null` puts the
  /// transport in local-only mode.
  final String? serverUrl;

  /// Opaque per-client auth token (issued by the server's `genkey`/`adduser`
  /// commands). Stored in the App Group for the extension to read.
  final String? serverToken;

  /// Debug flag: when true, the macOS Network Extension exercises the
  /// `BondedClient` encode path for every outbound packet in addition to
  /// the legacy per-flow forwarder. With no `serverUrl` set, frames are
  /// `OSLog`-inspectable but not actually transmitted — Phase 8 will
  /// connect this path to a real Speed Server. Always `false` in
  /// production for now.
  final bool bondedTransport;

  /// When true, each link runs a recurring HTTP probe against Apple's
  /// captive-portal endpoint (or any equivalent target). Links that come
  /// back as `captive` are effectively demoted to `Backup` priority by
  /// the controller's policy view until they pass again. Disabled by
  /// default so this only kicks in for users who want it.
  final bool captivePortalAssist;

  const Policy({
    this.mode = BondingMode.speed,
    this.links = const <Link>[],
    this.killSwitch = false,
    this.streamingDetection = true,
    this.dnsServers = const <String>[],
    this.splitTunnelAllowList = const <String>[],
    this.serverUrl,
    this.serverToken,
    this.bondedTransport = false,
    this.captivePortalAssist = false,
  });

  Policy copyWith({
    BondingMode? mode,
    List<Link>? links,
    bool? killSwitch,
    bool? streamingDetection,
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
      streamingDetection: streamingDetection ?? this.streamingDetection,
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
      'streamingDetection': streamingDetection,
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
      streamingDetection: _coerceBool(json['streamingDetection'], fallback: true),
      dnsServers: _coerceStringList(json['dnsServers']),
      splitTunnelAllowList: _coerceStringList(json['splitTunnelAllowList']),
      serverUrl: json['serverUrl'] as String?,
      serverToken: json['serverToken'] as String?,
      bondedTransport: _coerceBool(json['bondedTransport'], fallback: false),
      captivePortalAssist:
          _coerceBool(json['captivePortalAssist'], fallback: false),
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
