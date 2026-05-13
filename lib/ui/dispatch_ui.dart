import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/link_metric.dart';

class DispatchColors {
  static const Color ink = Color(0xff16181d);
  static const Color muted = Color(0xff626977);
  static const Color border = Color(0xffd9dde6);
  static const Color surface = Color(0xfffbfbfd);
  static const Color panel = Color(0xffffffff);
  static const Color accent = Color(0xff1f6feb);
  static const Color danger = Color(0xffc7362f);
  static const Color ok = Color(0xff238636);
  static const Color warn = Color(0xffd29922);

  /// Stable per-link color derived deterministically from the link's id.
  ///
  /// The dashboard uses this for sparkline strokes and link-card accents
  /// so the same link reads the same color everywhere at a glance. The hue
  /// is hashed mod 360 with a fixed
  /// saturation/lightness window chosen for contrast against
  /// [DispatchColors.panel].
  ///
  /// The mapping is pure: same `linkId` always returns the same color across
  /// process restarts. We use FNV-1a 32-bit because Dart's String.hashCode
  /// is not stable across releases.
  static Color linkColorFor(String linkId) {
    int hash = 0x811C9DC5; // FNV-1a 32-bit offset basis
    for (int i = 0; i < linkId.length; i++) {
      hash ^= linkId.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    double hue = (hash & 0xFFFF) % 360.0;
    // Saturation 60% and lightness 45% gives strong, distinguishable colors
    // that still read well as a thin stroke on the light panel background.
    return HSLColor.fromAHSL(1.0, hue, 0.60, 0.45).toColor();
  }
}

ThemeData buildDispatchTheme() {
  ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: DispatchColors.accent,
    brightness: Brightness.light,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme.copyWith(
      surface: DispatchColors.surface,
      primary: DispatchColors.accent,
      error: DispatchColors.danger,
    ),
    scaffoldBackgroundColor: DispatchColors.surface,
    fontFamily: 'SF Pro Display',
    textTheme: const TextTheme(
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: DispatchColors.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: DispatchColors.ink,
      ),
      bodyMedium: TextStyle(fontSize: 13, color: DispatchColors.ink),
      bodySmall: TextStyle(fontSize: 12, color: DispatchColors.muted),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DispatchColors.panel,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: DispatchColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: DispatchColors.border),
      ),
    ),
  );
}

class DispatchSection extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const DispatchSection({
    required this.title,
    required this.child,
    this.trailing,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        border: Border.all(color: DispatchColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          const Divider(height: 1, color: DispatchColors.border),
          child,
        ],
      ),
    );
  }
}

class DispatchBadge extends StatelessWidget {
  final String label;
  final Color color;

  const DispatchBadge({required this.label, required this.color, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class DenseIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const DenseIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 18),
        onPressed: onPressed,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// Selects how a [LinkMetric] should be extracted into a single double value
/// for plotting / badging. Each kind also defines its own "good", "warn", and
/// "danger" thresholds so a single badge can self-color from raw data.
enum MetricKind { rtt, jitter, loss, mos, throughputDown, throughputUp }

extension MetricKindAccessors on MetricKind {
  /// Short label rendered in [MetricBadge]'s title row.
  String get label {
    switch (this) {
      case MetricKind.rtt:
        return 'RTT';
      case MetricKind.jitter:
        return 'Jitter';
      case MetricKind.loss:
        return 'Loss';
      case MetricKind.mos:
        return 'MOS';
      case MetricKind.throughputDown:
        return 'Down';
      case MetricKind.throughputUp:
        return 'Up';
    }
  }

  /// Suffix appended to the formatted numeric value (e.g. "ms", "%").
  String get unit {
    switch (this) {
      case MetricKind.rtt:
      case MetricKind.jitter:
        return 'ms';
      case MetricKind.loss:
        return '%';
      case MetricKind.mos:
        return '';
      case MetricKind.throughputDown:
      case MetricKind.throughputUp:
        return '';
    }
  }

  /// Returns null when the corresponding field hasn't been populated yet.
  ///
  /// Loss is stored on [LinkMetric] as a `0.0..1.0` fraction; this accessor
  /// surfaces it as a percentage (0..100) so the badge / sparkline math and
  /// the thresholds below speak the same language.
  double? read(LinkMetric metric) {
    switch (this) {
      case MetricKind.rtt:
        return metric.rttMs;
      case MetricKind.jitter:
        return metric.jitterMs;
      case MetricKind.loss:
        double? l = metric.loss;
        return l == null ? null : l * 100.0;
      case MetricKind.mos:
        return metric.mos;
      case MetricKind.throughputDown:
        return metric.bpsIn?.toDouble();
      case MetricKind.throughputUp:
        return metric.bpsOut?.toDouble();
    }
  }

  /// Picks a color band based on Speedify-style thresholds. Lower-is-better
  /// for RTT/jitter/loss; higher-is-better for MOS and throughput.
  Color colorFor(double value) {
    switch (this) {
      case MetricKind.rtt:
        if (value < 60) return DispatchColors.ok;
        if (value < 150) return DispatchColors.warn;
        return DispatchColors.danger;
      case MetricKind.jitter:
        if (value < 10) return DispatchColors.ok;
        if (value < 30) return DispatchColors.warn;
        return DispatchColors.danger;
      case MetricKind.loss:
        if (value < 0.5) return DispatchColors.ok;
        if (value < 2.0) return DispatchColors.warn;
        return DispatchColors.danger;
      case MetricKind.mos:
        if (value >= 4.0) return DispatchColors.ok;
        if (value >= 3.0) return DispatchColors.warn;
        return DispatchColors.danger;
      case MetricKind.throughputDown:
      case MetricKind.throughputUp:
        // Throughput badges are neutral; there is no "bad throughput" signal
        // without a configured speed cap (Phase 3 will wire that in).
        return DispatchColors.accent;
    }
  }

  String format(double value) {
    switch (this) {
      case MetricKind.rtt:
      case MetricKind.jitter:
        return value < 10 ? value.toStringAsFixed(1) : value.toStringAsFixed(0);
      case MetricKind.loss:
        return value.toStringAsFixed(value < 1 ? 2 : 1);
      case MetricKind.mos:
        return value.toStringAsFixed(2);
      case MetricKind.throughputDown:
      case MetricKind.throughputUp:
        return _formatBitrate(value);
    }
  }

  static String _formatBitrate(double bps) {
    if (bps < 1000) {
      return '${bps.toStringAsFixed(0)} bps';
    }
    if (bps < 1000 * 1000) {
      return '${(bps / 1000).toStringAsFixed(1)} kbps';
    }
    if (bps < 1000 * 1000 * 1000) {
      return '${(bps / (1000 * 1000)).toStringAsFixed(1)} Mbps';
    }
    return '${(bps / (1000 * 1000 * 1000)).toStringAsFixed(2)} Gbps';
  }
}

/// Small chip showing one metric: label, formatted value with unit, and a
/// status dot colored by the metric kind's thresholds. Renders an em-dash
/// when [metric] is null or the requested field is unset.
class MetricBadge extends StatelessWidget {
  final MetricKind kind;
  final LinkMetric? metric;

  const MetricBadge({required this.kind, required this.metric, super.key});

  @override
  Widget build(BuildContext context) {
    double? value = metric == null ? null : kind.read(metric!);
    Color dot = value == null ? DispatchColors.muted : kind.colorFor(value);
    String text = value == null
        ? '—'
        : '${kind.format(value)}${kind.unit.isEmpty ? '' : ' ${kind.unit}'}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        border: Border.all(color: DispatchColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            kind.label,
            style: const TextStyle(
              color: DispatchColors.muted,
              fontWeight: FontWeight.w600,
              fontSize: 10.5,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: value == null ? DispatchColors.muted : DispatchColors.ink,
              fontWeight: FontWeight.w700,
              fontSize: 11.5,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Stateless painter that draws a 60-sample sparkline for one [MetricKind].
///
/// The painter auto-scales to the visible value range so a quiet 5 ms link
/// and a loaded 200 ms link both render with useful detail. Samples without
/// a value are drawn as gaps so the eye can spot probe failures.
class SparklinePainter extends CustomPainter {
  final List<LinkMetric> samples;
  final MetricKind kind;
  final Color color;
  final double strokeWidth;

  /// Optional fixed min/max. Pass when the caller wants stable axes (e.g.
  /// always 0..1 for loss). Leaving these null auto-fits.
  final double? minOverride;
  final double? maxOverride;

  SparklinePainter({
    required this.samples,
    required this.kind,
    required this.color,
    this.strokeWidth = 1.5,
    this.minOverride,
    this.maxOverride,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty || size.width <= 0 || size.height <= 0) {
      return;
    }

    List<double?> values = samples
        .map((LinkMetric m) => kind.read(m))
        .toList(growable: false);

    Iterable<double> present = values.whereType<double>();
    if (present.isEmpty) {
      return;
    }

    double minV = minOverride ?? present.reduce(math.min);
    double maxV = maxOverride ?? present.reduce(math.max);
    if ((maxV - minV).abs() < 1e-9) {
      // Avoid divide-by-zero on a perfectly flat line.
      maxV = minV + 1;
    }

    Paint stroke = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    Paint fill = Paint()
      ..color = color.withValues(alpha: 0.10)
      ..style = PaintingStyle.fill;

    Path linePath = Path();
    Path fillPath = Path();
    bool penDown = false;
    double? lastX;

    for (int i = 0; i < values.length; i++) {
      double? v = values[i];
      double x = values.length == 1
          ? size.width / 2
          : (i / (values.length - 1)) * size.width;
      if (v == null) {
        penDown = false;
        continue;
      }
      double normalized = ((v - minV) / (maxV - minV)).clamp(0.0, 1.0);
      double y = size.height - normalized * size.height;
      if (!penDown) {
        linePath.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
        penDown = true;
      } else {
        linePath.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
      lastX = x;
    }
    if (lastX != null) {
      fillPath.lineTo(lastX, size.height);
      fillPath.close();
    }

    canvas.drawPath(fillPath, fill);
    canvas.drawPath(linePath, stroke);
  }

  @override
  bool shouldRepaint(covariant SparklinePainter oldDelegate) {
    return oldDelegate.samples != samples ||
        oldDelegate.kind != kind ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.minOverride != minOverride ||
        oldDelegate.maxOverride != maxOverride;
  }
}

/// Convenience wrapper around [SparklinePainter] with sensible defaults so
/// callers don't have to instantiate the painter manually.
class Sparkline extends StatelessWidget {
  final List<LinkMetric> samples;
  final MetricKind kind;
  final Color color;
  final double height;

  const Sparkline({
    required this.samples,
    required this.kind,
    required this.color,
    this.height = 28,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: SparklinePainter(samples: samples, kind: kind, color: color),
        size: Size.infinite,
      ),
    );
  }
}
