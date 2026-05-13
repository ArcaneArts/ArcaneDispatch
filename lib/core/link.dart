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
///   need both v4 and v6.
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
    bool looksLikeIp =
        RegExp(r'[:.]').hasMatch(target) && !target.contains(' ');
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
