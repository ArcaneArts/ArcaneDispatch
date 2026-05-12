/// One row in the per-connection flow inspector.
///
/// The Flutter UI renders the most recent ~20 of these from the
/// [DispatchController]. Transports stream [FlowStat] updates as flows open /
/// close / accumulate bytes; the controller keeps a small sliding window per
/// flow id.
class FlowStat {
  /// Stable per-flow id. Transport-defined; for SOCKS it's the local socket
  /// hash, for the tunnel it's a 64-bit flow key derived from the IP 5-tuple.
  final String flowId;

  /// Foreign key into [Link.id] selected for this flow.
  final String linkId;

  /// Remote hostname when known (after SOCKS domain resolution) or `null` if
  /// we only have an IP literal.
  final String? remoteHost;

  /// Remote IP literal (always present once a connection is open).
  final String remoteAddress;

  /// Remote port.
  final int remotePort;

  /// IP protocol number (6 = TCP, 17 = UDP).
  final int protocol;

  /// Bytes received from the remote.
  final int bytesIn;

  /// Bytes sent to the remote.
  final int bytesOut;

  /// When the flow was first observed.
  final DateTime openedAt;

  /// When the flow closed, `null` if it's still open.
  final DateTime? closedAt;

  /// Loose tag set by the streaming detector (Phase 12). `null` while
  /// detection is off / undecided.
  final String? trafficClass;

  const FlowStat({
    required this.flowId,
    required this.linkId,
    required this.remoteAddress,
    required this.remotePort,
    required this.openedAt,
    this.remoteHost,
    this.protocol = 6,
    this.bytesIn = 0,
    this.bytesOut = 0,
    this.closedAt,
    this.trafficClass,
  });

  bool get isOpen {
    return closedAt == null;
  }

  Duration get duration {
    return (closedAt ?? DateTime.now()).difference(openedAt);
  }

  FlowStat addBytes({int inDelta = 0, int outDelta = 0}) {
    return FlowStat(
      flowId: flowId,
      linkId: linkId,
      remoteAddress: remoteAddress,
      remotePort: remotePort,
      openedAt: openedAt,
      remoteHost: remoteHost,
      protocol: protocol,
      bytesIn: bytesIn + inDelta,
      bytesOut: bytesOut + outDelta,
      closedAt: closedAt,
      trafficClass: trafficClass,
    );
  }

  FlowStat close({DateTime? at}) {
    return FlowStat(
      flowId: flowId,
      linkId: linkId,
      remoteAddress: remoteAddress,
      remotePort: remotePort,
      openedAt: openedAt,
      remoteHost: remoteHost,
      protocol: protocol,
      bytesIn: bytesIn,
      bytesOut: bytesOut,
      closedAt: at ?? DateTime.now(),
      trafficClass: trafficClass,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'flowId': flowId,
      'linkId': linkId,
      'remoteHost': remoteHost,
      'remoteAddress': remoteAddress,
      'remotePort': remotePort,
      'protocol': protocol,
      'bytesIn': bytesIn,
      'bytesOut': bytesOut,
      'openedAt': openedAt.toUtc().toIso8601String(),
      'closedAt': closedAt?.toUtc().toIso8601String(),
      'trafficClass': trafficClass,
    };
  }

  factory FlowStat.fromJson(Map<String, Object?> json) {
    return FlowStat(
      flowId: (json['flowId'] as String?) ?? '',
      linkId: (json['linkId'] as String?) ?? '',
      remoteAddress: (json['remoteAddress'] as String?) ?? '0.0.0.0',
      remotePort: _coerceInt(json['remotePort']) ?? 0,
      openedAt: _parseTime(json['openedAt']) ?? DateTime.now().toUtc(),
      remoteHost: json['remoteHost'] as String?,
      protocol: _coerceInt(json['protocol']) ?? 6,
      bytesIn: _coerceInt(json['bytesIn']) ?? 0,
      bytesOut: _coerceInt(json['bytesOut']) ?? 0,
      closedAt: _parseTime(json['closedAt']),
      trafficClass: json['trafficClass'] as String?,
    );
  }

  static int? _coerceInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  static DateTime? _parseTime(Object? value) {
    if (value is String) {
      return DateTime.tryParse(value)?.toUtc();
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    return null;
  }
}
