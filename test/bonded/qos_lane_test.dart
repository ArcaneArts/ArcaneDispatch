// Phase 12 QoS lane tests. Locks the invariant that `isRealtime: true`
// changes mode strategy decisions for streaming/voice flows.

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/bonded/bonded_modes.dart';
import 'package:arcane_dispatch/bonded/bonded_scheduler.dart';
import 'package:arcane_dispatch/core/link.dart';

BondedScheduler _twoPrimaryScheduler() {
  BondedScheduler s = BondedScheduler();
  s.updateLinks(<BondedLinkState>[
    BondedLinkState(
      linkId: 'cell',
      wireId: 1,
      priority: LinkPriority.primary,
      status: LinkStatus.healthy,
      rttMs: 80, // slower
      bandwidthBps: 10_000_000,
    ),
    BondedLinkState(
      linkId: 'wifi',
      wireId: 2,
      priority: LinkPriority.primary,
      status: LinkStatus.healthy,
      rttMs: 12, // fastest
      bandwidthBps: 50_000_000,
    ),
    BondedLinkState(
      linkId: 'wired',
      wireId: 3,
      priority: LinkPriority.secondary,
      status: LinkStatus.healthy,
      rttMs: 5,
      bandwidthBps: 1_000_000_000,
    ),
  ]);
  return s;
}

void main() {
  group('SpeedStrategy QoS lane', () {
    test('RT chunks bypass credit and pin to lowest-RTT primary', () {
      BondedScheduler s = _twoPrimaryScheduler();
      // Pre-load wifi with a huge inflight backlog so the credit scheduler
      // would normally prefer cell for the next bulk chunk.
      s.bookInflight('wifi', 100_000_000);

      BondedChunkPlan rt = const SpeedStrategy().planChunk(
        bytes: 200,
        scheduler: s,
        isRealtime: true,
      );
      expect(rt.fanout, 1);
      expect(rt.sends.single.linkId, 'wifi',
          reason: 'RT chunks must use lowest-RTT primary regardless of credit');
    });

    test('bulk chunks still respect credit (no QoS routing)', () {
      BondedScheduler s = _twoPrimaryScheduler();
      // Saturate wifi so the credit picker prefers cell.
      s.bookInflight('wifi', 100_000_000);

      BondedChunkPlan bulk = const SpeedStrategy().planChunk(
        bytes: 200,
        scheduler: s,
      );
      expect(bulk.fanout, 1);
      expect(bulk.sends.single.linkId, isNot('wifi'),
          reason: 'Bulk chunks must avoid the saturated link.');
    });

    test('RT falls back to credit picker when no primary is healthy', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        // Both "primaries" are dead — RT must still ship via a secondary.
        BondedLinkState(
          linkId: 'cell',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.unhealthy,
        ),
        BondedLinkState(
          linkId: 'wired',
          wireId: 2,
          priority: LinkPriority.secondary,
          status: LinkStatus.healthy,
          rttMs: 8,
          bandwidthBps: 100_000_000,
        ),
      ]);

      BondedChunkPlan rt = const SpeedStrategy().planChunk(
        bytes: 200,
        scheduler: s,
        isRealtime: true,
      );
      expect(rt.fanout, 1);
      expect(rt.sends.single.linkId, 'wired');
    });
  });

  group('StreamingStrategy QoS lane', () {
    test('RT chunks fan out to a secondary even with zero observed loss', () {
      BondedScheduler s = _twoPrimaryScheduler();
      // No bookings: lossFraction defaults to 0. Without isRealtime the
      // strategy would emit a single send.
      BondedChunkPlan bulk = const StreamingStrategy()
          .planChunk(bytes: 200, scheduler: s);
      expect(bulk.fanout, 1,
          reason: 'Bulk on zero-loss network is a single send.');

      BondedChunkPlan rt = const StreamingStrategy().planChunk(
        bytes: 200,
        scheduler: s,
        isRealtime: true,
      );
      expect(rt.fanout, 2,
          reason: 'RT chunk should be duplicated to a secondary regardless of loss.');
      Set<String> ids =
          rt.sends.map((BondedSendPlan p) => p.linkId).toSet();
      expect(ids.length, 2, reason: 'Two different links must be picked.');
    });

    test('RT bumps to single send when no secondary is available', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          rttMs: 12,
          bandwidthBps: 50_000_000,
        ),
      ]);

      BondedChunkPlan rt = const StreamingStrategy().planChunk(
        bytes: 200,
        scheduler: s,
        isRealtime: true,
      );
      expect(rt.fanout, 1);
      expect(rt.sends.single.linkId, 'wifi');
    });
  });

  group('RedundantStrategy QoS lane', () {
    test('RT chunks behave identically to bulk (already redundant)', () {
      BondedScheduler s = _twoPrimaryScheduler();
      BondedChunkPlan bulk = const RedundantStrategy()
          .planChunk(bytes: 200, scheduler: s);
      BondedChunkPlan rt = const RedundantStrategy().planChunk(
        bytes: 200,
        scheduler: s,
        isRealtime: true,
      );
      expect(rt.fanout, bulk.fanout);
      expect(
        rt.sends.map((BondedSendPlan p) => p.linkId).toSet(),
        bulk.sends.map((BondedSendPlan p) => p.linkId).toSet(),
      );
    });
  });
}
