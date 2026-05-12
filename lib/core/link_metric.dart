import 'dart:math' as math;

/// One sample of a [Link]'s health.
///
/// All fields are nullable except [linkId] and [capturedAt] so partial probes
/// can publish what they have. Consumers should treat null = "no data this
/// tick" and *not* assume zero (zero loss != "we have no loss reading").
///
/// Persisted as JSON in the metric ring buffer; also mirrored in the App Group
/// `metrics.bin` for the Network Extension (Phase 5+).
class LinkMetric {
  /// Foreign key into [Link.id].
  final String linkId;

  /// Sample timestamp.
  final DateTime capturedAt;

  /// Round-trip time (ms). Should reflect the most recent successful probe.
  final double? rttMs;

  /// Jitter (ms). Population stddev of recent RTT samples.
  final double? jitterMs;

  /// Packet/probe loss expressed as `0.0..1.0` (NOT 0..100). Use 0.05 for 5 %.
  final double? loss;

  /// Mean Opinion Score (1.0..4.5) computed by the E-model approximation.
  final double? mos;

  /// Inbound throughput in bytes per second (EWMA over ~1 s window).
  final double? bpsIn;

  /// Outbound throughput in bytes per second (EWMA over ~1 s window).
  final double? bpsOut;

  const LinkMetric({
    required this.linkId,
    required this.capturedAt,
    this.rttMs,
    this.jitterMs,
    this.loss,
    this.mos,
    this.bpsIn,
    this.bpsOut,
  });

  /// Compute MOS from rtt / jitter / loss using the E-model approximation
  /// commonly used for VoIP quality estimation. Returns a value in
  /// `[1.0, 4.5]` so the UI can map it directly to a color band.
  ///
  /// Source: ITU-T G.107 simplified, parameters tuned to match Speedify's
  /// scoring band (green > 4.0, yellow 3.0–4.0, red < 3.0).
  static double estimateMos({
    required double rttMs,
    required double jitterMs,
    required double lossPct,
  }) {
    double effectiveLatency = rttMs + jitterMs * 2.0 + 10.0;
    double rDelay = effectiveLatency < 160.0
        ? effectiveLatency / 40.0
        : (effectiveLatency - 120.0) / 10.0;
    double rLoss = lossPct * 2.5;
    double r = 93.2 - rDelay - rLoss;
    if (r < 0.0) {
      r = 0.0;
    }
    if (r > 100.0) {
      r = 100.0;
    }
    double mos = 1.0 + 0.035 * r + r * (r - 60.0) * (100.0 - r) * 7.0e-6;
    if (mos.isNaN || mos < 1.0) {
      return 1.0;
    }
    if (mos > 4.5) {
      return 4.5;
    }
    return mos;
  }

  /// Convenience: returns a copy with `mos` computed from rtt/jitter/loss
  /// when those are known and `mos` isn't already set.
  LinkMetric withDerivedMos() {
    if (mos != null) {
      return this;
    }
    if (rttMs == null || jitterMs == null || loss == null) {
      return this;
    }
    return LinkMetric(
      linkId: linkId,
      capturedAt: capturedAt,
      rttMs: rttMs,
      jitterMs: jitterMs,
      loss: loss,
      mos: estimateMos(
        rttMs: rttMs!,
        jitterMs: jitterMs!,
        lossPct: math.min(100.0, math.max(0.0, loss! * 100.0)),
      ),
      bpsIn: bpsIn,
      bpsOut: bpsOut,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'linkId': linkId,
      'capturedAt': capturedAt.toUtc().toIso8601String(),
      'rttMs': rttMs,
      'jitterMs': jitterMs,
      'loss': loss,
      'mos': mos,
      'bpsIn': bpsIn,
      'bpsOut': bpsOut,
    };
  }

  factory LinkMetric.fromJson(Map<String, Object?> json) {
    return LinkMetric(
      linkId: (json['linkId'] as String?) ?? '',
      capturedAt: _parseTime(json['capturedAt']),
      rttMs: _coerceDouble(json['rttMs']),
      jitterMs: _coerceDouble(json['jitterMs']),
      loss: _coerceDouble(json['loss']),
      mos: _coerceDouble(json['mos']),
      bpsIn: _coerceDouble(json['bpsIn']),
      bpsOut: _coerceDouble(json['bpsOut']),
    );
  }

  static DateTime _parseTime(Object? value) {
    if (value is String) {
      DateTime? parsed = DateTime.tryParse(value);
      if (parsed != null) {
        return parsed.toUtc();
      }
    }
    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }
    return DateTime.now().toUtc();
  }

  static double? _coerceDouble(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }
}
