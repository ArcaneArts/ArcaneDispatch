import 'dart:math' as math;

import '../core/bonding_mode.dart';
import '../core/link.dart';
import 'bonded_scheduler.dart';

typedef BondedSendPlan = BondedSchedulingDecision;

class BondedChunkPlan {
  final List<BondedSendPlan> sends;
  final bool inflightBooked;

  const BondedChunkPlan({required this.sends, this.inflightBooked = true});

  factory BondedChunkPlan.empty() {
    return const BondedChunkPlan(sends: <BondedSendPlan>[]);
  }

  bool get isEmpty => sends.isEmpty;
  int get fanout => sends.length;
}

abstract class BondedModeStrategy {
  BondingMode get mode;

  BondedChunkPlan planChunk({
    required int bytes,
    required BondedScheduler scheduler,
  });

  static BondedModeStrategy forMode(BondingMode mode) {
    switch (mode) {
      case BondingMode.speed:
        return const SpeedStrategy();
      case BondingMode.redundant:
        return const RedundantStrategy();
    }
  }
}

class SpeedStrategy implements BondedModeStrategy {
  const SpeedStrategy();

  @override
  BondingMode get mode => BondingMode.speed;

  @override
  BondedChunkPlan planChunk({
    required int bytes,
    required BondedScheduler scheduler,
  }) {
    BondedSendPlan? decision = scheduler.pickLink(bytes: bytes);
    if (decision == null) {
      return BondedChunkPlan.empty();
    }
    return BondedChunkPlan(sends: <BondedSendPlan>[decision]);
  }
}

class RedundantStrategy implements BondedModeStrategy {
  const RedundantStrategy();

  @override
  BondingMode get mode => BondingMode.redundant;

  @override
  BondedChunkPlan planChunk({
    required int bytes,
    required BondedScheduler scheduler,
  }) {
    List<BondedLinkState> links = _eligibleLinks(scheduler);
    if (links.isEmpty) {
      return BondedChunkPlan.empty();
    }
    List<BondedSendPlan> sends = <BondedSendPlan>[];
    for (BondedLinkState state in links) {
      scheduler.bookInflight(state.linkId, bytes);
      sends.add(
        BondedSendPlan(
          linkId: state.linkId,
          wireId: state.wireId,
          credit: 0,
          wasRoundRobinFallback: false,
        ),
      );
    }
    return BondedChunkPlan(sends: sends, inflightBooked: true);
  }

  List<BondedLinkState> _eligibleLinks(BondedScheduler scheduler) {
    Map<String, BondedLinkState> states = scheduler.states;
    for (LinkPriority bucket in const <LinkPriority>[
      LinkPriority.primary,
      LinkPriority.secondary,
      LinkPriority.backup,
    ]) {
      List<BondedLinkState> links = <BondedLinkState>[];
      for (BondedLinkState state in states.values) {
        if (state.priority != bucket) {
          continue;
        }
        if (state.status == LinkStatus.unhealthy ||
            state.status == LinkStatus.disabled) {
          continue;
        }
        links.add(state);
      }
      if (links.isNotEmpty) {
        return links;
      }
    }
    return const <BondedLinkState>[];
  }
}

double clampFractionForTest(double value) {
  return math.max(0.05, math.min(1.0, value));
}
