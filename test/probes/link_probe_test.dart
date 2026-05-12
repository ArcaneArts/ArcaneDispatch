import 'dart:async';
import 'dart:io';

import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/link_metric.dart';
import 'package:arcane_dispatch/probes/link_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helper that builds a probe with a deterministic attempt function and a
/// fast tick interval so we can drive its loop manually.
LinkProbe _probe({
  required List<ProbeOutcome> outcomes,
  Duration interval = const Duration(milliseconds: 10),
  int windowSize = 5,
  InternetAddress? source,
}) {
  int idx = 0;
  return LinkProbe(
    link: Link(id: 'l', label: 'L', interfaceName: 'en0'),
    resolveSource: () => source ?? InternetAddress.loopbackIPv4,
    config: LinkProbeConfig(
      tickInterval: interval,
      attemptTimeout: const Duration(seconds: 1),
      windowSize: windowSize,
      targets: const <ProbeTarget>[
        ProbeTarget(host: '127.0.0.1', port: 65535),
      ],
    ),
    attempt: ({
      required InternetAddress target,
      required int port,
      required InternetAddress? sourceAddress,
      required Duration timeout,
    }) async {
      ProbeOutcome out = outcomes[idx % outcomes.length];
      idx += 1;
      return out;
    },
  );
}

void main() {
  group('LinkProbe', () {
    test('emits metric with rtt + jitter + loss after a few ticks', () async {
      LinkProbe probe = _probe(
        outcomes: <ProbeOutcome>[
          const ProbeOutcome.success(10.0),
          const ProbeOutcome.success(12.0),
          const ProbeOutcome.success(8.0),
        ],
        interval: const Duration(milliseconds: 5),
      );
      List<LinkMetric> samples = <LinkMetric>[];
      StreamSubscription<LinkMetric> sub = probe.stream.listen(samples.add);
      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      probe.cancelTimer();
      await sub.cancel();
      await probe.stop();

      expect(samples, isNotEmpty);
      LinkMetric latest = samples.last;
      expect(latest.linkId, 'l');
      expect(latest.rttMs, isNotNull);
      expect(latest.jitterMs, isNotNull);
      expect(latest.loss, 0.0);
      expect(latest.mos, isNotNull);
    });

    test('loss climbs when probes fail', () async {
      LinkProbe probe = _probe(
        outcomes: <ProbeOutcome>[
          const ProbeOutcome.failure('timeout'),
          const ProbeOutcome.failure('timeout'),
          const ProbeOutcome.failure('timeout'),
        ],
        interval: const Duration(milliseconds: 5),
        windowSize: 3,
      );
      List<LinkMetric> samples = <LinkMetric>[];
      StreamSubscription<LinkMetric> sub = probe.stream.listen(samples.add);
      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      probe.cancelTimer();
      await sub.cancel();
      await probe.stop();

      expect(samples, isNotEmpty);
      LinkMetric latest = samples.last;
      expect(latest.loss, 1.0);
      expect(latest.rttMs, isNull); // no successful samples yet
    });

    test('uses last successful rtt when current probe fails', () async {
      LinkProbe probe = _probe(
        outcomes: <ProbeOutcome>[
          const ProbeOutcome.success(20.0),
          const ProbeOutcome.failure('timeout'),
        ],
        interval: const Duration(milliseconds: 5),
        windowSize: 4,
      );
      List<LinkMetric> samples = <LinkMetric>[];
      StreamSubscription<LinkMetric> sub = probe.stream.listen(samples.add);
      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      probe.cancelTimer();
      await sub.cancel();
      await probe.stop();

      LinkMetric latest = samples.last;
      // After at least one tick of each, we should have a non-null rtt and
      // some loss in the window.
      expect(latest.rttMs, isNotNull);
      expect(latest.loss, greaterThan(0.0));
    });

    test('marks as failed when source resolution returns null but expected',
        () async {
      LinkProbe probe = LinkProbe(
        link: Link(
          id: 'l',
          label: 'l',
          sourceAddress: '10.0.0.99',
        ),
        resolveSource: () => null, // expected an address, got nothing
        config: const LinkProbeConfig(
          tickInterval: Duration(milliseconds: 5),
          windowSize: 2,
        ),
        attempt: ({
          required InternetAddress target,
          required int port,
          required InternetAddress? sourceAddress,
          required Duration timeout,
        }) async {
          // Should never be reached when source resolution fails.
          return const ProbeOutcome.success(0);
        },
      );
      List<LinkMetric> samples = <LinkMetric>[];
      StreamSubscription<LinkMetric> sub = probe.stream.listen(samples.add);
      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      probe.cancelTimer();
      await sub.cancel();
      await probe.stop();

      LinkMetric latest = samples.last;
      expect(latest.loss, 1.0);
    });

    test('cancelTimer stops emissions synchronously', () async {
      LinkProbe probe = _probe(
        outcomes: <ProbeOutcome>[const ProbeOutcome.success(5.0)],
        interval: const Duration(milliseconds: 5),
      );
      probe.start();
      probe.cancelTimer();
      int before = (await probe.stream
              .take(0)
              .toList()
              .timeout(const Duration(milliseconds: 30), onTimeout: () => <LinkMetric>[]))
          .length;
      expect(before, 0);
      await probe.stop();
    });

    test('latest exposes the most recent metric', () async {
      LinkProbe probe = _probe(
        outcomes: <ProbeOutcome>[const ProbeOutcome.success(7.0)],
        interval: const Duration(milliseconds: 5),
      );
      expect(probe.latest, isNull);
      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      probe.cancelTimer();
      await probe.stop();
      expect(probe.latest, isNotNull);
      expect(probe.latest!.rttMs, 7.0);
    });
  });
}
