import 'dart:convert';

/// Priority bucket assigned to a [Link] by the user.
///
/// Routes are tried top-down: [primary] is preferred while any primary is
/// healthy, otherwise [secondary], then [backup]. [never] is excluded
/// entirely.
enum LinkPriority { primary, secondary, backup, never }

extension LinkPriorityCodec on LinkPriority {
  String get wireName {
    switch (this) {
      case LinkPriority.primary:
        return 'primary';
      case LinkPriority.secondary:
        return 'secondary';
      case LinkPriority.backup:
        return 'backup';
      case LinkPriority.never:
        return 'never';
    }
  }

  static LinkPriority parse(
    Object? value, {
    LinkPriority fallback = LinkPriority.primary,
  }) {
    if (value is LinkPriority) {
      return value;
    }
    if (value is String) {
      for (LinkPriority priority in LinkPriority.values) {
        if (priority.wireName == value) {
          return priority;
        }
      }
    }
    return fallback;
  }
}

/// Coarse health state of a [Link] as seen by the supervisor.
enum LinkStatus { unknown, healthy, degraded, unhealthy, disabled }

/// Source-of-bytes classification for a [Link]. Most uplinks are
/// [LinkKind.local] (a real network interface on this machine). Paired
/// peers (Phase 13 "Pair & Share") show up as [LinkKind.paired] so the
/// dispatcher can treat them as virtual interfaces that need an extra
/// hop through the peer's bonded server.
enum LinkKind { local, paired }

extension LinkKindCodec on LinkKind {
  String get wireName {
    switch (this) {
      case LinkKind.local:
        return 'local';
      case LinkKind.paired:
        return 'paired';
    }
  }

  static LinkKind parse(Object? value, {LinkKind fallback = LinkKind.local}) {
    if (value is LinkKind) {
      return value;
    }
    if (value is String) {
      for (LinkKind kind in LinkKind.values) {
        if (kind.wireName == value) {
          return kind;
        }
      }
    }
    return fallback;
  }
}

extension LinkStatusCodec on LinkStatus {
  String get wireName {
    switch (this) {
      case LinkStatus.unknown:
        return 'unknown';
      case LinkStatus.healthy:
        return 'healthy';
      case LinkStatus.degraded:
        return 'degraded';
      case LinkStatus.unhealthy:
        return 'unhealthy';
      case LinkStatus.disabled:
        return 'disabled';
    }
  }

  static LinkStatus parse(
    Object? value, {
    LinkStatus fallback = LinkStatus.unknown,
  }) {
    if (value is LinkStatus) {
      return value;
    }
    if (value is String) {
      for (LinkStatus status in LinkStatus.values) {
        if (status.wireName == value) {
          return status;
        }
      }
    }
    return fallback;
  }
}

/// A user-configured uplink that the bonded transport may bind to.
///
/// A [Link] is the persisted *intent* — what the user picked and how they want
/// it treated. The runtime metric stream lives separately in `LinkMetric` so
/// that the policy graph stays immutable / cheap to copy.
///
/// Field semantics:
///
/// * [id] — Stable identifier, generated once. Used as the join key for
///   metrics, flows, and the App Group shared state.
/// * [label] — Human display name. Defaults to the interface name.
/// * [interfaceName] — Optional system interface name (e.g. `en0`). When null,
///   [sourceAddress] alone is used; either must resolve to a usable source IP.
/// * [sourceAddress] — Literal source IP/CIDR override. Free-form because we
///   need both v4 and v6, plus eventual virtual links (Pair & Share).
/// * [priority] — Routing bucket; see [LinkPriority].
/// * [weight] — Integer weight inside the priority bucket. Maps onto the
///   legacy `<target>/<weight>` syntax. Kept as int for fixed-point dispatch.
/// * [speedCapBps] — Per-link throughput cap in bytes/second. `null` = no cap.
/// * [dataCapBytes] — Per-billing-cycle data allowance in bytes. `null` = no cap.
/// * [dataUsedBytes] — Counter that the data-meter increments. Resets on
///   [billingCycleAnchor].
/// * [billingCycleAnchor] — Day-of-month or ISO-date used for monthly rollover.
///   Stored as ISO-8601 string for cross-platform parsing.
/// * [status] — Last-known health state, written by the supervisor. Persisted
///   so the UI can show a meaningful state on cold boot.
class Link {
  final String id;
  final String label;
  final String? interfaceName;
  final String? sourceAddress;
  final LinkPriority priority;
  final int weight;
  final int? speedCapBps;
  final int? dataCapBytes;
  final int dataUsedBytes;
  final String? billingCycleAnchor;
  final LinkStatus status;
  /// What kind of uplink this is. `local` for real interfaces, `paired`
  /// for a Pair & Share peer that bridges its internet.
  final LinkKind kind;
  /// For `LinkKind.paired` only: the `host:port` of the peer's bonded
  /// endpoint. Ignored for local links.
  final String? pairedEndpoint;
  /// For `LinkKind.paired` only: hex fingerprint (first 16 hex chars of
  /// SHA-256(peerPublicKey)) used to display "connected to: 8f…" and to
  /// reject mismatched re-pairs.
  final String? pairedFingerprint;

  const Link({
    required this.id,
    required this.label,
    this.interfaceName,
    this.sourceAddress,
    this.priority = LinkPriority.primary,
    this.weight = 1,
    this.speedCapBps,
    this.dataCapBytes,
    this.dataUsedBytes = 0,
    this.billingCycleAnchor,
    this.status = LinkStatus.unknown,
    this.kind = LinkKind.local,
    this.pairedEndpoint,
    this.pairedFingerprint,
  });

  /// Legacy `<target>[/weight]` tokens migrate to a [Link] via this factory.
  ///
  /// Used by [DispatchSettings] when reading the pre-v1 `selected_targets` key.
  factory Link.fromLegacyTarget(String token) {
    String trimmed = token.trim();
    String target = trimmed;
    int weight = 1;
    int slash = trimmed.indexOf('/');
    if (slash >= 0) {
      target = trimmed.substring(0, slash).trim();
      int? parsed = int.tryParse(trimmed.substring(slash + 1).trim());
      if (parsed != null && parsed > 0) {
        weight = parsed;
      }
    }
    bool looksLikeIp = RegExp(r'[:.]').hasMatch(target) && !target.contains(' ');
    return Link(
      id: 'legacy:$target',
      label: target,
      interfaceName: looksLikeIp ? null : target,
      sourceAddress: looksLikeIp ? target : null,
      weight: weight,
    );
  }

  /// Legacy `<target>[/weight]` rendering used by transports that still speak
  /// the old [WeightedAddressResolver] API.
  String toLegacyTarget() {
    String target = interfaceName ?? sourceAddress ?? label;
    return weight <= 1 ? target : '$target/$weight';
  }

  Link copyWith({
    String? id,
    String? label,
    Object? interfaceName = _sentinel,
    Object? sourceAddress = _sentinel,
    LinkPriority? priority,
    int? weight,
    Object? speedCapBps = _sentinel,
    Object? dataCapBytes = _sentinel,
    int? dataUsedBytes,
    Object? billingCycleAnchor = _sentinel,
    LinkStatus? status,
    LinkKind? kind,
    Object? pairedEndpoint = _sentinel,
    Object? pairedFingerprint = _sentinel,
  }) {
    return Link(
      id: id ?? this.id,
      label: label ?? this.label,
      interfaceName: identical(interfaceName, _sentinel)
          ? this.interfaceName
          : interfaceName as String?,
      sourceAddress: identical(sourceAddress, _sentinel)
          ? this.sourceAddress
          : sourceAddress as String?,
      priority: priority ?? this.priority,
      weight: weight ?? this.weight,
      speedCapBps: identical(speedCapBps, _sentinel)
          ? this.speedCapBps
          : speedCapBps as int?,
      dataCapBytes: identical(dataCapBytes, _sentinel)
          ? this.dataCapBytes
          : dataCapBytes as int?,
      dataUsedBytes: dataUsedBytes ?? this.dataUsedBytes,
      billingCycleAnchor: identical(billingCycleAnchor, _sentinel)
          ? this.billingCycleAnchor
          : billingCycleAnchor as String?,
      status: status ?? this.status,
      kind: kind ?? this.kind,
      pairedEndpoint: identical(pairedEndpoint, _sentinel)
          ? this.pairedEndpoint
          : pairedEndpoint as String?,
      pairedFingerprint: identical(pairedFingerprint, _sentinel)
          ? this.pairedFingerprint
          : pairedFingerprint as String?,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'label': label,
      'interfaceName': interfaceName,
      'sourceAddress': sourceAddress,
      'priority': priority.wireName,
      'weight': weight,
      'speedCapBps': speedCapBps,
      'dataCapBytes': dataCapBytes,
      'dataUsedBytes': dataUsedBytes,
      'billingCycleAnchor': billingCycleAnchor,
      'status': status.wireName,
      'kind': kind.wireName,
      'pairedEndpoint': pairedEndpoint,
      'pairedFingerprint': pairedFingerprint,
    };
  }

  factory Link.fromJson(Map<String, Object?> json) {
    return Link(
      id: (json['id'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      interfaceName: json['interfaceName'] as String?,
      sourceAddress: json['sourceAddress'] as String?,
      priority: LinkPriorityCodec.parse(json['priority']),
      weight: _coerceWeight(json['weight']),
      speedCapBps: _coercePositiveInt(json['speedCapBps']),
      dataCapBytes: _coercePositiveInt(json['dataCapBytes']),
      dataUsedBytes: _coercePositiveInt(json['dataUsedBytes']) ?? 0,
      billingCycleAnchor: json['billingCycleAnchor'] as String?,
      status: LinkStatusCodec.parse(json['status']),
      kind: LinkKindCodec.parse(json['kind']),
      pairedEndpoint: json['pairedEndpoint'] as String?,
      pairedFingerprint: json['pairedFingerprint'] as String?,
    );
  }

  String encode() {
    return jsonEncode(toJson());
  }

  static Link decode(String source) {
    Object? raw = jsonDecode(source);
    if (raw is Map<String, Object?>) {
      return Link.fromJson(raw);
    }
    if (raw is Map) {
      return Link.fromJson(raw.cast<String, Object?>());
    }
    throw FormatException('Link payload is not a JSON object: $source');
  }

  @override
  String toString() {
    return 'Link(id=$id, label=$label, priority=${priority.wireName}, weight=$weight)';
  }

  static int _coerceWeight(Object? value) {
    if (value is int && value > 0) {
      return value;
    }
    if (value is num && value > 0) {
      return value.toInt();
    }
    if (value is String) {
      int? parsed = int.tryParse(value);
      if (parsed != null && parsed > 0) {
        return parsed;
      }
    }
    return 1;
  }

  static int? _coercePositiveInt(Object? value) {
    if (value is int && value >= 0) {
      return value;
    }
    if (value is num && value >= 0) {
      return value.toInt();
    }
    if (value is String) {
      int? parsed = int.tryParse(value);
      if (parsed != null && parsed >= 0) {
        return parsed;
      }
    }
    return null;
  }
}

const Object _sentinel = Object();
