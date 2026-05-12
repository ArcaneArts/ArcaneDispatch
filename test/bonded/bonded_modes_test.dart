// Phase 10 mode-strategy tests. These exercise the strategies directly
// (no session/loopback) to lock in the per-mode link selection logic.

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/bonded/bonded_modes.dart';
import 'package:arcane_dispatch/bonded/bonded_scheduler.dart';
import 'package:arcane_dispatch/core/bonding_mode.dart';
import 'package:arcane_dispatch/core/link.dart';

void main() {
  group('BondedModeStrategy.forMode', () {
    test('returns the matching strategy class for each enum value', () {
      expect(BondedModeStrategy.forMode(BondingMode.speed),
          isA<SpeedStrategy>());
      expect(BondedModeStrategy.forMode(BondingMode.redundant),
          isA<RedundantStrategy>());
      expect(BondedModeStrategy.forMode(BondingMode.streaming),
          isA<StreamingStrategy>());
      expect(BondedModeStrategy.forMode(BondingMode.local),
          isA<LocalStrategy>());
    });
  });

  group('SpeedStrategy', () {
    test('emits a single send via scheduler.pickLink', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          rttMs: 20,
          bandwidthBps: 10_000_000,
        ),
      ]);

      BondedChunkPlan plan =
          const SpeedStrategy().planChunk(bytes: 1024, scheduler: s);
      expect(plan.fanout, 1);
      expect(plan.sends.first.linkId, 'wifi');
      expect(s.inflightForTest('wifi'), 1024);
    });

    test('empty plan when no healthy link is available', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'cell',
          wireId: 2,
          priority: LinkPriority.primary,
          status: LinkStatus.unhealthy,
        ),
      ]);

      BondedChunkPlan plan =
          const SpeedStrategy().planChunk(bytes: 1024, scheduler: s);
      expect(plan.isEmpty, isTrue);
    });
  });

  group('RedundantStrategy', () {
    test('fans out to every healthy primary link', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
        ),
        BondedLinkState(
          linkId: 'cell',
          wireId: 2,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
        ),
        BondedLinkState(
          linkId: 'wired',
          wireId: 3,
          priority: LinkPriority.secondary,
          status: LinkStatus.healthy,
        ),
      ]);

      BondedChunkPlan plan =
          const RedundantStrategy().planChunk(bytes: 512, scheduler: s);

      expect(plan.fanout, 2,
          reason: 'Both primaries get a copy; secondaries are skipped.');
      Set<String> ids = plan.sends.map((BondedSendPlan p) => p.linkId).toSet();
      expect(ids, <String>{'wifi', 'cell'});
      expect(s.inflightForTest('wifi'), 512);
      expect(s.inflightForTest('cell'), 512);
      expect(s.inflightForTest('wired'), 0);
    });

    test('falls back to secondary bucket when no primaries are healthy', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.unhealthy,
        ),
        BondedLinkState(
          linkId: 'cell',
          wireId: 2,
          priority: LinkPriority.secondary,
          status: LinkStatus.healthy,
        ),
      ]);

      BondedChunkPlan plan =
          const RedundantStrategy().planChunk(bytes: 256, scheduler: s);
      expect(plan.fanout, 1);
      expect(plan.sends.first.linkId, 'cell');
    });

    test('empty plan when no eligible link in any bucket', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          status: LinkStatus.disabled,
        ),
      ]);

      BondedChunkPlan plan =
          const RedundantStrategy().planChunk(bytes: 1024, scheduler: s);
      expect(plan.isEmpty, isTrue);
    });
  });

  group('StreamingStrategy', () {
    test('single send when loss is below threshold', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          lossFraction: 0.005,
          rttMs: 10,
          bandwidthBps: 100_000_000,
        ),
        BondedLinkState(
          linkId: 'cell',
          wireId: 2,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          lossFraction: 0.0,
          rttMs: 30,
          bandwidthBps: 50_000_000,
        ),
      ]);

      BondedChunkPlan plan =
          const StreamingStrategy().planChunk(bytes: 1024, scheduler: s);
      expect(plan.fanout, 1);
    });

    test('falls back to duplicate-on-loss when primary loss > threshold', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          lossFraction: 0.05, // 5 % loss > 1 % threshold
          rttMs: 15,
          bandwidthBps: 100_000_000,
        ),
        BondedLinkState(
          linkId: 'cell',
          wireId: 2,
          priority: LinkPriority.secondary,
          status: LinkStatus.healthy,
          lossFraction: 0.0,
          rttMs: 40,
          bandwidthBps: 30_000_000,
        ),
      ]);

      BondedChunkPlan plan =
          const StreamingStrategy().planChunk(bytes: 1024, scheduler: s);
      expect(plan.fanout, 2);
      Set<String> ids = plan.sends.map((BondedSendPlan p) => p.linkId).toSet();
      expect(ids, contains('cell'));
    });

    test('still single send when no secondary is available even with loss',
        () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          lossFraction: 0.1,
          rttMs: 15,
          bandwidthBps: 100_000_000,
        ),
      ]);

      BondedChunkPlan plan =
          const StreamingStrategy().planChunk(bytes: 1024, scheduler: s);
      expect(plan.fanout, 1);
    });

    test('respects inflightFraction cap', () {
      // With inflightFraction = 0.25, a low-BDP link should run out of
      // credit much faster than under Speed mode.
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          rttMs: 100,
          bandwidthBps: 1_000_000, // BDP ~ 100 kB, Streaming cap ~ 25 kB
        ),
      ]);

      double speedCredit = s.creditForTest('wifi', inflightFraction: 1.0);
      double streamCredit = s.creditForTest('wifi', inflightFraction: 0.25);
      expect(streamCredit, lessThan(speedCredit));
      expect(streamCredit, lessThanOrEqualTo(speedCredit / 3));
    });
  });

  group('LocalStrategy', () {
    test('behaves like Speed when no paired peer is in the link set', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          rttMs: 10,
          bandwidthBps: 100_000_000,
        ),
      ]);

      BondedChunkPlan plan =
          const LocalStrategy().planChunk(bytes: 256, scheduler: s);
      expect(plan.fanout, 1);
      expect(plan.sends.first.linkId, 'wifi');
    });

    test('prefers paired peer over local interfaces when both are healthy',
        () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          rttMs: 5,
          bandwidthBps: 100_000_000,
        ),
        BondedLinkState(
          linkId: 'paired:phone',
          wireId: 7,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          rttMs: 30,
          bandwidthBps: 20_000_000,
        ),
      ]);

      BondedChunkPlan plan =
          const LocalStrategy().planChunk(bytes: 1024, scheduler: s);
      expect(plan.fanout, 1);
      expect(plan.sends.first.linkId, 'paired:phone');
      expect(s.inflightForTest('paired:phone'), 1024);
      expect(s.inflightForTest('wifi'), 0,
          reason: 'Wifi must stay untouched when a paired peer is chosen.');
    });

    test('falls through to local pick when paired peer is unhealthy', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'paired:phone',
          wireId: 7,
          priority: LinkPriority.primary,
          status: LinkStatus.unhealthy,
        ),
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          rttMs: 5,
          bandwidthBps: 100_000_000,
        ),
      ]);

      BondedChunkPlan plan =
          const LocalStrategy().planChunk(bytes: 256, scheduler: s);
      expect(plan.fanout, 1);
      expect(plan.sends.first.linkId, 'wifi');
    });

    test('falls through when paired peer has been marked Never', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'paired:phone',
          wireId: 7,
          priority: LinkPriority.never,
          status: LinkStatus.healthy,
          rttMs: 30,
          bandwidthBps: 20_000_000,
        ),
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          rttMs: 5,
          bandwidthBps: 100_000_000,
        ),
      ]);

      BondedChunkPlan plan =
          const LocalStrategy().planChunk(bytes: 256, scheduler: s);
      expect(plan.fanout, 1);
      expect(plan.sends.first.linkId, 'wifi');
    });

    test('returns empty plan when nothing is eligible', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'paired:phone',
          wireId: 7,
          status: LinkStatus.disabled,
        ),
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          status: LinkStatus.unhealthy,
        ),
      ]);

      BondedChunkPlan plan =
          const LocalStrategy().planChunk(bytes: 256, scheduler: s);
      expect(plan.isEmpty, isTrue);
    });
  });

  test('clampFractionForTest bounds the strategy frac', () {
    expect(clampFractionForTest(0.0), 0.05);
    expect(clampFractionForTest(2.0), 1.0);
    expect(clampFractionForTest(0.5), 0.5);
  });
}
