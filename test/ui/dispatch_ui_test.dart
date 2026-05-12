import 'package:arcane_dispatch/ui/dispatch_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DispatchColors.linkColorFor', () {
    test('returns the same color for the same linkId across calls', () {
      // The mapping is pure — required for the dashboard to read the same
      // color across the sparkline, link card stripe, and flow inspector
      // rows for a given link.
      Color a = DispatchColors.linkColorFor('wifi-en0');
      Color b = DispatchColors.linkColorFor('wifi-en0');
      Color c = DispatchColors.linkColorFor('wifi-en0');
      expect(a, equals(b));
      expect(b, equals(c));
    });

    test('returns visibly different colors for different linkIds', () {
      // We don't lock the exact RGB values (that would over-constrain the
      // hash), but two unrelated link ids should land far apart on the hue
      // wheel. Compare hue distance >= 20 deg.
      Color a = DispatchColors.linkColorFor('wifi-en0');
      Color b = DispatchColors.linkColorFor('cell-pdp0');
      Color c = DispatchColors.linkColorFor('eth-en6');
      HSLColor ha = HSLColor.fromColor(a);
      HSLColor hb = HSLColor.fromColor(b);
      HSLColor hc = HSLColor.fromColor(c);
      expect(_hueDist(ha.hue, hb.hue), greaterThanOrEqualTo(20));
      expect(_hueDist(ha.hue, hc.hue), greaterThanOrEqualTo(20));
      expect(_hueDist(hb.hue, hc.hue), greaterThanOrEqualTo(20));
    });

    test('saturation and lightness are within the contrast window', () {
      // Saturation 0.6, lightness 0.45 chosen for readability on the panel
      // background. Confirm we always land in this band (allowing for the
      // small HSL → RGB → HSL round-trip drift that Flutter applies).
      for (String id in <String>[
        'a',
        'wifi-en0',
        'cell-pdp0',
        'eth-en6',
        'paired-mac-1',
        'paired-mac-2',
        '🔥',
      ]) {
        HSLColor h = HSLColor.fromColor(DispatchColors.linkColorFor(id));
        expect(h.saturation, closeTo(0.60, 0.02));
        expect(h.lightness, closeTo(0.45, 0.02));
      }
    });

    test('an empty linkId returns a deterministic color', () {
      // Edge case — empty strings still need to round-trip cleanly so the
      // flow inspector handles flows without a populated linkId without
      // crashing.
      Color a = DispatchColors.linkColorFor('');
      Color b = DispatchColors.linkColorFor('');
      expect(a, equals(b));
    });
  });
}

/// Shortest hue distance on a 0..360 wheel.
double _hueDist(double a, double b) {
  double diff = (a - b).abs();
  return diff > 180 ? 360 - diff : diff;
}
