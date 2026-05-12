import 'dart:async';
import 'dart:io';

import 'package:arcane_dispatch/core/link_metric.dart';
import 'package:arcane_dispatch/probes/link_metric_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

LinkMetric _m(String id, double rtt, [DateTime? t]) {
  return LinkMetric(
    linkId: id,
    capturedAt: t ?? DateTime.utc(2026, 5, 11),
    rttMs: rtt,
  );
}

void main() {
  group('LinkMetricStore', () {
    test('record updates latest and history per link', () {
      LinkMetricStore store = LinkMetricStore(windowSize: 4);
      store.record(_m('a', 1));
      store.record(_m('a', 2));
      store.record(_m('b', 99));
      expect(store.latestFor('a')!.rttMs, 2);
      expect(store.latestFor('b')!.rttMs, 99);
      expect(store.historyFor('a').map((LinkMetric x) => x.rttMs).toList(),
          <double>[1, 2]);
      expect(store.historyFor('b').map((LinkMetric x) => x.rttMs).toList(),
          <double>[99]);
    });

    test('ring buffer evicts oldest at window size', () {
      LinkMetricStore store = LinkMetricStore(windowSize: 3);
      for (int i = 1; i <= 5; i++) {
        store.record(_m('a', i.toDouble()));
      }
      expect(store.historyFor('a').map((LinkMetric x) => x.rttMs).toList(),
          <double>[3, 4, 5]);
    });

    test('dropLink removes both buffer and latest', () {
      LinkMetricStore store = LinkMetricStore();
      store.record(_m('a', 1));
      store.dropLink('a');
      expect(store.latestFor('a'), isNull);
      expect(store.historyFor('a'), isEmpty);
    });

    test('metrics stream broadcasts each record', () async {
      LinkMetricStore store = LinkMetricStore();
      List<LinkMetric> seen = <LinkMetric>[];
      StreamSubscription<LinkMetric> sub = store.metrics.listen(seen.add);
      store.record(_m('a', 1));
      store.record(_m('a', 2));
      await Future<void>.delayed(Duration.zero);
      expect(seen.map((LinkMetric x) => x.rttMs), <double>[1, 2]);
      await sub.cancel();
      await store.dispose();
    });

    group('persistence', () {
      late Directory tempDir;
      late Box box;

      setUp(() async {
        tempDir =
            await Directory.systemTemp.createTemp('arcane_dispatch_store_test_');
        Hive.init(tempDir.path);
        box = await Hive.openBox('test_store');
      });

      tearDown(() async {
        await box.close();
        await Hive.deleteFromDisk();
        await tempDir.delete(recursive: true);
      });

      test('flush writes latest per link to Hive as JSON', () async {
        LinkMetricStore store = LinkMetricStore(storage: box);
        store.record(_m('a', 12));
        store.record(_m('b', 34));
        await store.flush();
        Object? raw = box.get('link_metrics_snapshot_v1');
        expect(raw, isA<String>());
        expect((raw as String).contains('"a"'), isTrue);
        expect(raw.contains('"linkId":"b"'), isTrue);
        await store.dispose();
      });

      test('warmStart rehydrates latest map from previous flush', () async {
        // Write a snapshot via one store, read with another.
        LinkMetricStore writer = LinkMetricStore(storage: box);
        writer.record(_m('a', 7));
        writer.record(_m('b', 8));
        await writer.flush();
        await writer.dispose();

        LinkMetricStore reader = LinkMetricStore(storage: box);
        Map<String, LinkMetric> seeded = reader.warmStart();
        expect(seeded.keys.toSet(), <String>{'a', 'b'});
        expect(seeded['a']!.rttMs, 7);
        expect(seeded['b']!.rttMs, 8);
        expect(reader.latestFor('a')!.rttMs, 7);
        await reader.dispose();
      });

      test('warmStart tolerates corrupt blob', () async {
        await box.put('link_metrics_snapshot_v1', '{not json');
        LinkMetricStore store = LinkMetricStore(storage: box);
        expect(store.warmStart(), isEmpty);
        await store.dispose();
      });

      test('startSnapshots schedules periodic flush', () async {
        LinkMetricStore store = LinkMetricStore(
          storage: box,
          snapshotInterval: const Duration(milliseconds: 20),
        );
        store.record(_m('a', 1));
        store.startSnapshots();
        // Wait long enough for at least one snapshot tick.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await store.dispose();
        expect(box.get('link_metrics_snapshot_v1'), isNotNull);
      });

      test('dispose cancels the snapshot timer synchronously', () async {
        LinkMetricStore store = LinkMetricStore(
          storage: box,
          snapshotInterval: const Duration(seconds: 60),
        );
        store.startSnapshots();
        await store.dispose();
        // No timer should remain; we exercise this indirectly: a second
        // dispose is a no-op and shouldn't throw.
        await store.dispose();
      });
    });
  });
}
