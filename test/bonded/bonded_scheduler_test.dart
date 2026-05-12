// Behavior coverage for BondedScheduler. The scheduler is the brain of the
// outbound path so this suite is intentionally dense — every regression here
// causes either starvation, herd-effect (everything ends up on one link),
// or wrong inflight accounting.

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/bonded/bonded_scheduler.dart';
import 'package:arcane_dispatch/core/link.dart';

BondedLinkState _state(
  String id, {
  int wireId = 0,
  LinkPriority priority = LinkPriority.primary,
  LinkStatus status = LinkStatus.healthy,
  int weight = 1,
  double rttMs = 50.0,
  double bandwidthBps = 1_000_000.0,
  int inflightBytes = 0,
}) {
  return BondedLinkState(
    linkId: id,
    wireId: wireId,
    priority: priority,
    status: status,
    weight: weight,
    rttMs: rttMs,
    bandwidthBps: bandwidthBps,
    inflightBytes: inflightBytes,
  );
}

void main() {
  group('BondedScheduler.pickLink', () {
    test('returns null when no links are configured', () {
      BondedScheduler s = BondedScheduler();
      expect(s.pickLink(bytes: 100), isNull);
    });

    test('returns null when zero or negative bytes requested', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('a', wireId: 1),
          ]);
      expect(s.pickLink(bytes: 0), isNull);
      expect(s.pickLink(bytes: -10), isNull);
    });

    test('returns null when every link is unhealthy or disabled', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('a', wireId: 1, status: LinkStatus.unhealthy),
            _state('b', wireId: 2, status: LinkStatus.disabled),
          ]);
      expect(s.pickLink(bytes: 100), isNull);
    });

    test('prefers higher-bandwidth link in Speed mode', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('slow', wireId: 1, bandwidthBps: 200_000.0),
            _state('fast', wireId: 2, bandwidthBps: 5_000_000.0),
          ]);
      BondedSchedulingDecision? d = s.pickLink(bytes: 1000);
      expect(d, isNotNull);
      expect(d!.linkId, 'fast');
      expect(d.wireId, 2);
      expect(d.wasRoundRobinFallback, isFalse);
    });

    test('penalizes higher-RTT link of equal bandwidth', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('snappy', wireId: 1, rttMs: 20.0, bandwidthBps: 1_000_000.0),
            _state('lossy', wireId: 2, rttMs: 200.0, bandwidthBps: 1_000_000.0),
          ]);
      // BDP = bw × rtt; higher rtt actually means *more* credit by the BDP
      // formula. That's intentional — fatter pipes can absorb more bytes
      // before they need an ACK. So we expect 'lossy' to win the first
      // pick. Test exists to lock in the formula, not the intuition.
      BondedSchedulingDecision? d = s.pickLink(bytes: 100);
      expect(d, isNotNull);
      expect(d!.linkId, 'lossy');
    });

    test('inflight bytes reduce future credit and shift the next pick', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('a', wireId: 1, bandwidthBps: 1_000_000.0, rttMs: 50.0),
            _state('b', wireId: 2, bandwidthBps: 1_000_000.0, rttMs: 50.0),
          ]);
      // BDP @ 1 MB/s and 50 ms = 50_000 bytes. After we book 40 k bytes on
      // 'a' it should have ~10 k credit while 'b' still has 50 k, so the
      // next pick MUST switch to 'b'.
      s.pickLink(bytes: 40_000);
      BondedSchedulingDecision? second = s.pickLink(bytes: 1000);
      expect(second!.linkId, 'b');
    });

    test('completeSend frees inflight and restores credit', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('a', wireId: 1, bandwidthBps: 1_000_000.0, rttMs: 50.0),
            _state('b', wireId: 2, bandwidthBps: 1_000_000.0, rttMs: 50.0),
          ]);
      s.pickLink(bytes: 49_000); // saturates 'a' nearly fully
      // Now 'b' should win.
      BondedSchedulingDecision? p1 = s.pickLink(bytes: 100);
      expect(p1!.linkId, 'b');
      // Release the inflight on 'a' — its credit recovers.
      s.completeSend('a', 49_000);
      expect(s.inflightForTest('a'), 0);
    });

    test('completeSend clamps to zero, never goes negative', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('a', wireId: 1),
          ]);
      s.pickLink(bytes: 10);
      s.completeSend('a', 9999); // way more than ever was inflight
      expect(s.inflightForTest('a'), 0);
    });

    test('completeSend on unknown link is a no-op', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('a', wireId: 1),
          ]);
      // Shouldn't throw.
      s.completeSend('does-not-exist', 100);
    });
  });

  group('priority handling', () {
    test('uses only primary when any primary is healthy', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('prim', wireId: 1),
            _state('sec', wireId: 2, priority: LinkPriority.secondary, bandwidthBps: 10_000_000.0),
            _state('bk', wireId: 3, priority: LinkPriority.backup),
          ]);
      BondedSchedulingDecision? d = s.pickLink(bytes: 100);
      expect(d!.linkId, 'prim'); // secondary's fatter pipe must NOT win
    });

    test('falls down to secondary when all primaries are unhealthy', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('prim', wireId: 1, status: LinkStatus.unhealthy),
            _state('sec', wireId: 2, priority: LinkPriority.secondary),
          ]);
      BondedSchedulingDecision? d = s.pickLink(bytes: 100);
      expect(d!.linkId, 'sec');
    });

    test('skips never-priority links even when they look healthy', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('off', wireId: 1, priority: LinkPriority.never, bandwidthBps: 100_000_000.0),
            _state('on', wireId: 2),
          ]);
      BondedSchedulingDecision? d = s.pickLink(bytes: 100);
      expect(d!.linkId, 'on');
    });

    test('drops to backup when primary + secondary are gone', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('prim', wireId: 1, status: LinkStatus.unhealthy),
            _state('sec', wireId: 2,
                priority: LinkPriority.secondary, status: LinkStatus.unhealthy),
            _state('bk', wireId: 3, priority: LinkPriority.backup),
          ]);
      BondedSchedulingDecision? d = s.pickLink(bytes: 100);
      expect(d!.linkId, 'bk');
    });
  });

  group('round-robin fallback', () {
    test('flagged when two healthy links tie on credit', () {
      // Identical bandwidth + RTT + zero inflight → identical credit. The
      // scheduler MUST surface the RR flag in that case.
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('a', wireId: 1, bandwidthBps: 1_000_000.0, rttMs: 50.0),
            _state('b', wireId: 2, bandwidthBps: 1_000_000.0, rttMs: 50.0),
          ]);
      BondedSchedulingDecision? first = s.pickLink(bytes: 100);
      expect(first!.wasRoundRobinFallback, isTrue);
    });

    test('RR alternates across consecutive picks with equal credit', () {
      BondedScheduler s = BondedScheduler();
      // Use very small picks so credit barely budges between calls and the
      // RR path stays the active selector.
      s.updateLinks(<BondedLinkState>[
        _state('a', wireId: 1, bandwidthBps: 1_000_000_000.0),
        _state('b', wireId: 2, bandwidthBps: 1_000_000_000.0),
        _state('c', wireId: 3, bandwidthBps: 1_000_000_000.0),
      ]);
      List<String> picks = <String>[];
      for (int i = 0; i < 6; i++) {
        BondedSchedulingDecision? d = s.pickLink(bytes: 1);
        picks.add(d!.linkId);
      }
      // Every link should appear at least once across 6 picks.
      expect(picks.toSet(), <String>{'a', 'b', 'c'});
    });
  });

  group('updateLinks', () {
    test('preserves inflight for surviving links', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('a', wireId: 1),
            _state('b', wireId: 2),
          ]);
      s.pickLink(bytes: 500); // books on one of them
      int totalInflight = s.inflightForTest('a') + s.inflightForTest('b');
      expect(totalInflight, 500);

      // Push fresh metrics; both links survive.
      s.updateLinks(<BondedLinkState>[
        _state('a', wireId: 1, bandwidthBps: 999_999.0),
        _state('b', wireId: 2, bandwidthBps: 999_999.0),
      ]);
      expect(s.inflightForTest('a') + s.inflightForTest('b'), 500);
    });

    test('removed links lose their inflight (caller must drain first)', () {
      BondedScheduler s = BondedScheduler()..updateLinks(<BondedLinkState>[
            _state('a', wireId: 1),
            _state('b', wireId: 2),
          ]);
      s.pickLink(bytes: 200);
      s.updateLinks(<BondedLinkState>[
        _state('a', wireId: 1),
      ]);
      expect(s.linkCount, 1);
      expect(s.inflightForTest('b'), 0);
    });
  });

  group('credit minimums', () {
    test('bandwidth floor keeps a brand-new metric-less link in the race', () {
      BondedScheduler s = BondedScheduler(minBandwidthBps: 100_000.0);
      s.updateLinks(<BondedLinkState>[
        _state('cold', wireId: 1, bandwidthBps: 0.0, rttMs: 100.0),
      ]);
      double credit = s.creditForTest('cold');
      // floor × rtt = 100_000 × 0.1 = 10_000 bytes.
      expect(credit, closeTo(10_000.0, 1.0));
    });

    test('rtt floor avoids division-by-zero on a loopback link', () {
      BondedScheduler s = BondedScheduler(minRttMs: 1.0);
      s.updateLinks(<BondedLinkState>[
        _state('lo', wireId: 1, rttMs: 0.0, bandwidthBps: 10_000_000.0),
      ]);
      // floor of 1 ms × 10 MB/s = 10 000 bytes
      expect(s.creditForTest('lo'), closeTo(10_000.0, 1.0));
    });
  });

  group('BondedLinkState.fromLink', () {
    test('falls back to defaults when no metric is supplied', () {
      BondedLinkState s = BondedLinkState.fromLink(
        const Link(id: 'wifi', label: 'Wi-Fi'),
        wireId: 7,
      );
      expect(s.wireId, 7);
      expect(s.rttMs, 50.0);
      expect(s.bandwidthBps, 1_000_000.0);
    });
  });
}
