// Per-mode scheduling strategies for the bonded transport.
//
// The `BondedScheduler` from Phase 7 picks ONE link per chunk using a
// BBR-style credit formula. That's the right answer for Speed mode but
// the wrong answer for Redundant (duplicate-fan-out), Streaming (smaller
// inflight budget + RT prioritisation), or Local (peer-to-peer).
//
// Phase 10 layers a strategy on top: `BondedSession` asks the strategy
// "how should I send this chunk?" and gets back a *list* of decisions.
// Speed returns one entry; Redundant returns N. The session keeps owning
// the framing/seq/retransmit machinery — the strategy is pure decision
// logic.
//
// Mirrors Swift `BondedModeStrategy` in
// `macos/ArcaneDispatchTunnel/Bonded/BondedModes.swift`.

import 'dart:math' as math;

import '../core/bonding_mode.dart';
import '../core/link.dart';
import 'bonded_scheduler.dart';

/// A single (linkId, wireId, credit) tuple. Same shape as
/// [BondedSchedulingDecision] but the strategy may emit more than one.
/// Aliased here so call sites don't have to know we share the struct.
typedef BondedSendPlan = BondedSchedulingDecision;

/// Per-chunk plan emitted by [BondedModeStrategy.planChunk]. The session
/// iterates this list and encodes one wire frame per entry — all sharing
/// the same outbound seq so the receiver naturally de-dupes via the
/// reassembler's `droppedDuplicate` path.
class BondedChunkPlan {
  /// Ordered list of link picks for this chunk. Empty means "drop or
  /// queue, no eligible links right now". A length of 1 is the Speed-mode
  /// happy path; higher counts are Redundant / Streaming-fallback.
  final List<BondedSendPlan> sends;

  /// If true, the scheduler's inflight counters have already been booked
  /// (the strategy did the bookings itself when it called `pickLink`).
  /// Strategies that synthesise their picks instead of calling the
  /// scheduler must book inflight via [BondedScheduler.bookInflight] or
  /// leave this false so the session books on their behalf.
  final bool inflightBooked;

  const BondedChunkPlan({
    required this.sends,
    this.inflightBooked = true,
  });

  factory BondedChunkPlan.empty() {
    return const BondedChunkPlan(sends: <BondedSendPlan>[]);
  }

  bool get isEmpty => sends.isEmpty;
  int get fanout => sends.length;
}

/// Strategy contract. Stateless w.r.t. the scheduler; the strategy reads
/// scheduler state via the passed-in instance but doesn't own it.
abstract class BondedModeStrategy {
  /// Identifier surfaced to telemetry / the UI.
  BondingMode get mode;

  /// Plan how to ship a chunk of `bytes` bytes. The implementation may
  /// consult [scheduler] for credit and book inflight via
  /// [BondedScheduler.pickLink].
  ///
  /// When [isRealtime] is true (Phase 12 QoS lane) the strategy picks the
  /// lowest-RTT primary link regardless of credit, and Streaming mode
  /// additionally fans out to a secondary even when loss is low. Bulk
  /// chunks (the default) keep the existing throughput-optimised
  /// behaviour.
  BondedChunkPlan planChunk({
    required int bytes,
    required BondedScheduler scheduler,
    bool isRealtime = false,
  });

  /// Factory that picks a strategy for [mode]. Centralised so the session
  /// + UI agree on which class implements each mode.
  static BondedModeStrategy forMode(BondingMode mode) {
    switch (mode) {
      case BondingMode.speed:
        return const SpeedStrategy();
      case BondingMode.redundant:
        return const RedundantStrategy();
      case BondingMode.streaming:
        return const StreamingStrategy();
      case BondingMode.local:
        return const LocalStrategy();
    }
  }
}

/// Default Speed mode: delegate straight to the credit scheduler.
class SpeedStrategy implements BondedModeStrategy {
  const SpeedStrategy();

  @override
  BondingMode get mode => BondingMode.speed;

  @override
  BondedChunkPlan planChunk({
    required int bytes,
    required BondedScheduler scheduler,
    bool isRealtime = false,
  }) {
    if (isRealtime) {
      // QoS lane: pick the lowest-RTT healthy primary regardless of
      // credit. We still book inflight so the bulk scheduler sees the
      // bytes and adjusts subsequent picks accordingly.
      BondedLinkState? rt = _lowestRttPrimary(scheduler);
      if (rt != null) {
        scheduler.bookInflight(rt.linkId, bytes);
        return BondedChunkPlan(
          sends: <BondedSendPlan>[
            BondedSendPlan(
              linkId: rt.linkId,
              wireId: rt.wireId,
              credit: 0,
              wasRoundRobinFallback: false,
            ),
          ],
          inflightBooked: true,
        );
      }
      // Fall through to the credit picker when no primary is healthy.
    }
    BondedSendPlan? d = scheduler.pickLink(bytes: bytes);
    if (d == null) {
      return BondedChunkPlan.empty();
    }
    return BondedChunkPlan(sends: <BondedSendPlan>[d]);
  }

  static BondedLinkState? _lowestRttPrimary(BondedScheduler scheduler) {
    BondedLinkState? winner;
    double bestRtt = double.infinity;
    for (BondedLinkState s in scheduler.states.values) {
      if (s.priority != LinkPriority.primary) continue;
      if (s.status == LinkStatus.unhealthy ||
          s.status == LinkStatus.disabled) {
        continue;
      }
      if (s.rttMs < bestRtt) {
        winner = s;
        bestRtt = s.rttMs;
      }
    }
    return winner;
  }
}

/// Redundant mode: ship the chunk on *every* healthy primary link. If no
/// primary links exist, fan out to the best non-`never` bucket instead so
/// the user still has redundancy on a degraded network.
class RedundantStrategy implements BondedModeStrategy {
  const RedundantStrategy();

  @override
  BondingMode get mode => BondingMode.redundant;

  @override
  BondedChunkPlan planChunk({
    required int bytes,
    required BondedScheduler scheduler,
    bool isRealtime = false,
  }) {
    List<BondedLinkState> primaries = _eligibleLinks(scheduler);
    if (primaries.isEmpty) {
      return BondedChunkPlan.empty();
    }
    List<BondedSendPlan> sends = <BondedSendPlan>[];
    for (BondedLinkState s in primaries) {
      // We book inflight ourselves so the credit signals remain
      // meaningful for a future Speed-mode switch mid-flow.
      scheduler.bookInflight(s.linkId, bytes);
      sends.add(BondedSendPlan(
        linkId: s.linkId,
        wireId: s.wireId,
        credit: 0,
        wasRoundRobinFallback: false,
      ));
    }
    return BondedChunkPlan(sends: sends, inflightBooked: true);
  }

  /// Healthy links in the best bucket that has any.
  List<BondedLinkState> _eligibleLinks(BondedScheduler scheduler) {
    Map<String, BondedLinkState> states = scheduler.states;
    for (LinkPriority bucket in const <LinkPriority>[
      LinkPriority.primary,
      LinkPriority.secondary,
      LinkPriority.backup,
    ]) {
      List<BondedLinkState> ids = <BondedLinkState>[];
      for (BondedLinkState s in states.values) {
        if (s.priority != bucket) continue;
        if (s.status == LinkStatus.unhealthy ||
            s.status == LinkStatus.disabled) {
          continue;
        }
        ids.add(s);
      }
      if (ids.isNotEmpty) return ids;
    }
    return const <BondedLinkState>[];
  }
}

/// Streaming mode: like Speed, but with a tight inflight cap (1× BDP
/// instead of 4×) so jitter stays low. When *any* eligible link is
/// observing > 1 % loss the chunk falls back to Redundant fan-out to that
/// link plus the next-best so RT flows survive bursty drops.
///
/// Loss data comes from the scheduler's per-link metrics (the metric
/// pump updates `BondedLinkState.lossFraction` via the scheduler).
class StreamingStrategy implements BondedModeStrategy {
  /// Loss fraction threshold above which we fall back to Redundant for
  /// the affected chunk. 0.01 = 1 %.
  final double lossDuplicateThreshold;

  /// Inflight cap multiplier. Speed mode treats BDP as the cap; Streaming
  /// shrinks it to keep queueing delay minimal.
  final double inflightFraction;

  const StreamingStrategy({
    this.lossDuplicateThreshold = 0.01,
    this.inflightFraction = 0.25,
  });

  @override
  BondingMode get mode => BondingMode.streaming;

  @override
  BondedChunkPlan planChunk({
    required int bytes,
    required BondedScheduler scheduler,
    bool isRealtime = false,
  }) {
    BondedSendPlan? primary = scheduler.pickLink(
      bytes: bytes,
      inflightFraction: inflightFraction,
    );
    if (primary == null) {
      return BondedChunkPlan.empty();
    }
    BondedLinkState? primaryState =
        scheduler.states[primary.linkId];
    double observedLoss = primaryState?.lossFraction ?? 0.0;
    // RT chunks always fan out when there's a viable secondary, regardless
    // of measured loss — they're cheap and they keep call audio glitch-free.
    bool shouldDuplicate =
        isRealtime || observedLoss >= lossDuplicateThreshold;
    if (!shouldDuplicate) {
      return BondedChunkPlan(sends: <BondedSendPlan>[primary]);
    }
    // Loss is high enough that we duplicate to a backup link if one is
    // available.
    BondedLinkState? secondary = _bestSecondary(
      scheduler,
      excludeLinkId: primary.linkId,
    );
    if (secondary == null) {
      return BondedChunkPlan(sends: <BondedSendPlan>[primary]);
    }
    scheduler.bookInflight(secondary.linkId, bytes);
    return BondedChunkPlan(
      sends: <BondedSendPlan>[
        primary,
        BondedSendPlan(
          linkId: secondary.linkId,
          wireId: secondary.wireId,
          credit: 0,
          wasRoundRobinFallback: false,
        ),
      ],
      inflightBooked: true,
    );
  }

  BondedLinkState? _bestSecondary(
    BondedScheduler scheduler, {
    required String excludeLinkId,
  }) {
    BondedLinkState? winner;
    double bestRtt = double.infinity;
    for (BondedLinkState s in scheduler.states.values) {
      if (s.linkId == excludeLinkId) continue;
      if (s.status == LinkStatus.unhealthy ||
          s.status == LinkStatus.disabled) {
        continue;
      }
      if (s.priority == LinkPriority.never) continue;
      if (s.rttMs < bestRtt) {
        winner = s;
        bestRtt = s.rttMs;
      }
    }
    return winner;
  }
}

/// Local-mode strategy used when bonding without a remote relay.
///
/// **Routing preference**: paired peers come first. When any paired link
/// (id prefix `paired:`) is healthy *and* has positive credit, Local
/// mode prefers it over local interfaces — this is the spec for "Local
/// mode active" with a Pair & Share peer attached. If no paired link is
/// available, falls through to a normal single-link pick. This keeps
/// Local mode useful both as the Pair & Share egress path and as a
/// no-server lab setup.
class LocalStrategy implements BondedModeStrategy {
  const LocalStrategy();

  @override
  BondingMode get mode => BondingMode.local;

  @override
  BondedChunkPlan planChunk({
    required int bytes,
    required BondedScheduler scheduler,
    bool isRealtime = false,
  }) {
    // First pass: try to pick a paired peer directly.
    BondedSendPlan? paired = _pickPaired(scheduler, bytes);
    if (paired != null) {
      return BondedChunkPlan(sends: <BondedSendPlan>[paired]);
    }
    // No paired peer eligible → fall back to whatever the scheduler picks.
    BondedSendPlan? d = scheduler.pickLink(bytes: bytes);
    if (d == null) {
      return BondedChunkPlan.empty();
    }
    return BondedChunkPlan(sends: <BondedSendPlan>[d]);
  }

  /// Returns the best paired link if one is healthy with credit, else
  /// null. The scheduler doesn't expose a "by-kind" lookup so we filter
  /// on the `paired:` linkId convention used by [Link] and the
  /// `PairedLinkRegistry`.
  BondedSendPlan? _pickPaired(BondedScheduler scheduler, int bytes) {
    Map<String, BondedLinkState> all = scheduler.states;
    BondedLinkState? best;
    double bestScore = -1;
    double bestCredit = 0;
    for (MapEntry<String, BondedLinkState> e in all.entries) {
      if (!e.key.startsWith('paired:')) continue;
      BondedLinkState s = e.value;
      if (s.status == LinkStatus.unhealthy ||
          s.status == LinkStatus.disabled) {
        continue;
      }
      if (s.priority == LinkPriority.never) continue;
      double credit = scheduler.creditFor(e.key);
      if (credit <= 0) continue;
      double score = credit / (1.0 + s.rttMs);
      if (score > bestScore) {
        bestScore = score;
        bestCredit = credit;
        best = s;
      }
    }
    if (best == null) return null;
    scheduler.bookInflight(best.linkId, bytes);
    return BondedSendPlan(
      linkId: best.linkId,
      wireId: best.wireId,
      credit: bestCredit,
      wasRoundRobinFallback: false,
    );
  }
}

/// Bound the float so the credit math doesn't tip into degenerate
/// territory. Exposed via top-level so tests can assert the same min in
/// the Swift mirror.
double clampFractionForTest(double v) {
  return math.max(0.05, math.min(1.0, v));
}
