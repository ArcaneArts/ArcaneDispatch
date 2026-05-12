import 'dart:io';

import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/policy/data_meter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  group('DataMeter', () {
    late Directory tempDir;
    late Box box;

    setUp(() async {
      tempDir =
          await Directory.systemTemp.createTemp('arcane_dispatch_data_meter_');
      Hive.init(tempDir.path);
      box = await Hive.openBox('test_meter');
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteFromDisk();
      await tempDir.delete(recursive: true);
    });

    test('recordBytes accumulates per link, snapshot returns flat map', () {
      DataMeter meter = DataMeter(storage: box);
      Link a = _link('a');
      Link b = _link('b');
      meter.recordBytes(a, 100);
      meter.recordBytes(a, 50);
      meter.recordBytes(b, 200);

      expect(meter.usedFor(a), 150);
      expect(meter.usedFor(b), 200);
      Map<String, int> snap = meter.snapshot();
      expect(snap['a'], 150);
      expect(snap['b'], 200);
    });

    test('negative / zero recordBytes is ignored', () {
      DataMeter meter = DataMeter(storage: box);
      Link a = _link('a');
      meter.recordBytes(a, 0);
      meter.recordBytes(a, -10);
      expect(meter.usedFor(a), 0);
    });

    test('isExhausted is false without cap, true at/above cap', () {
      DataMeter meter = DataMeter(storage: box);
      Link uncapped = _link('uncapped');
      Link capped = _link('capped', dataCapBytes: 1000);
      meter.recordBytes(uncapped, 5000);
      meter.recordBytes(capped, 999);
      expect(meter.isExhausted(uncapped), isFalse);
      expect(meter.isExhausted(capped), isFalse);
      meter.recordBytes(capped, 1);
      expect(meter.isExhausted(capped), isTrue);
      meter.recordBytes(capped, 100);
      expect(meter.isExhausted(capped), isTrue);
    });

    test('flush persists dirty counters to Hive', () async {
      DataMeter meter = DataMeter(storage: box);
      Link a = _link('a');
      meter.recordBytes(a, 256);
      await meter.flush();

      Object? raw = box.get('data_meter_v1/a');
      expect(raw, isA<String>());
      expect((raw as String).contains('"used":256'), isTrue);
    });

    test('reopening a meter rehydrates from Hive snapshot', () async {
      DataMeter m1 = DataMeter(storage: box);
      Link a = _link('a');
      m1.recordBytes(a, 999);
      await m1.flush();
      await m1.dispose();

      DataMeter m2 = DataMeter(storage: box);
      expect(m2.usedFor(a), 999);
    });

    test('reset zeroes the counter for a specific link', () {
      DataMeter meter = DataMeter(storage: box);
      Link a = _link('a');
      Link b = _link('b');
      meter.recordBytes(a, 500);
      meter.recordBytes(b, 300);
      meter.reset(a);
      expect(meter.usedFor(a), 0);
      expect(meter.usedFor(b), 300);
    });

    test('dispose flushes before sealing the meter', () async {
      DataMeter meter = DataMeter(storage: box);
      Link a = _link('a');
      meter.recordBytes(a, 42);
      await meter.dispose();

      Object? raw = box.get('data_meter_v1/a');
      expect(raw, isA<String>());
      expect((raw as String).contains('"used":42'), isTrue);
    });

    test('billing cycle rollover zeroes usage on month boundary', () async {
      // Anchor = 15th of each month. Start on Jan 20 (already inside the
      // Jan 15 -> Feb 15 cycle); record 500. Jump to Feb 16 (next cycle
      // started yesterday) and observe the rollover.
      DateTime fakeNow = DateTime.utc(2026, 1, 20, 12);
      DataMeter meter = DataMeter(
        storage: box,
        now: () => fakeNow,
      );
      Link a = _link('a', billingCycleAnchor: '15');
      meter.recordBytes(a, 500);
      expect(meter.usedFor(a), 500);

      // Advance past the Feb 15 anchor.
      fakeNow = DateTime.utc(2026, 2, 16, 0);
      // Reading usedFor triggers _maybeRollover.
      expect(meter.usedFor(a), 0);

      // New usage after rollover accumulates normally.
      meter.recordBytes(a, 25);
      expect(meter.usedFor(a), 25);
    });

    test('rollover writes the new cycleStart to Hive on next flush', () async {
      DateTime fakeNow = DateTime.utc(2026, 1, 20, 12);
      DataMeter meter = DataMeter(
        storage: box,
        now: () => fakeNow,
      );
      Link a = _link('a', billingCycleAnchor: '15');
      meter.recordBytes(a, 500);
      await meter.flush();

      // Advance past the Feb 15 anchor, then trigger a rollover via usedFor
      // and flush again.
      fakeNow = DateTime.utc(2026, 2, 16, 0);
      meter.usedFor(a);
      await meter.flush();

      String? raw = box.get('data_meter_v1/a') as String?;
      expect(raw, isNotNull);
      // Cycle start should now be Feb 15 (UTC) — the new cycle's anchor.
      expect(raw!.contains('2026-02-15'), isTrue);
    });

    test('ISO-date anchors are honored (day part used as monthly anchor)', () {
      DateTime fakeNow = DateTime.utc(2026, 1, 20, 12);
      DataMeter meter = DataMeter(
        storage: box,
        now: () => fakeNow,
      );
      Link a = _link('a', billingCycleAnchor: '2026-01-15');
      meter.recordBytes(a, 100);
      expect(meter.usedFor(a), 100);

      fakeNow = DateTime.utc(2026, 2, 16);
      expect(meter.usedFor(a), 0);
    });

    test('null anchor falls back to first of the month', () {
      DateTime fakeNow = DateTime.utc(2026, 1, 20, 12);
      DataMeter meter = DataMeter(
        storage: box,
        now: () => fakeNow,
      );
      Link a = _link('a'); // no anchor
      meter.recordBytes(a, 100);

      // Cross into February -> should reset.
      fakeNow = DateTime.utc(2026, 2, 1);
      expect(meter.usedFor(a), 0);
    });
  });
}

Link _link(
  String id, {
  int? dataCapBytes,
  String? billingCycleAnchor,
}) {
  return Link(
    id: id,
    label: id,
    interfaceName: 'en$id',
    dataCapBytes: dataCapBytes,
    billingCycleAnchor: billingCycleAnchor,
  );
}
