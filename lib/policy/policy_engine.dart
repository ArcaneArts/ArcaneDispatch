import 'dart:math' as math;

import '../core/link.dart';
import '../core/link_metric.dart';
import '../core/policy.dart';
import '../core/weighted_address.dart';

/// A link that the [PolicyEngine] has decided is currently eligible to carry
/// new flows. The [weight] is the *effective* weight after the health gate,
/// data-cap check, and speed-cap normalization have run.
///
/// Consumers (the SOCKS scheduler in Phase 3, the bonded scheduler in Phase 7)
/// only see this projection — they never need to re-read raw `Link` fields to
/// decide who gets the next flow. Keeping the engine pure makes it trivial to
/// unit test the cascade logic without spinning up sockets.
class EligibleLink {
  final Link link;

  /// Effective weight inside the active group. Integer so the dispatcher can
  /// use a classic weighted-RR token wheel. Always >= 1.
  final int weight;

  /// 0 = primary group active, 1 = secondary, 2 = backup. The engine only
  /// emits one group at a time; this field lets the UI render "you're on
  /// Secondary" banners without re-deriving from priorities.
  final int groupRank;

  /// What [link]'s priority bucket looked like when this decision was made.
  /// Equal to `link.priority` for the active group's members but informative
  /// for log lines like "primary degraded, dropped to secondary".
  final LinkPriority sourcePriority;

  const EligibleLink({
    required this.link,
    required this.weight,
    required this.groupRank,
    required this.sourcePriority,
  });

  @override
  String toString() {
    return 'EligibleLink(${link.id}, weight=$weight, group=$groupRank)';
  }
}

/// Why a [Link] was excluded from the active eligible set. Surfaced so the UI
/// can show a per-link "ineligible because X" badge without re-running the
/// rules client-side.
enum IneligibilityReason {
  never,
  noSource,
  highLoss,
  highRtt,
  dataCapExhausted,
  groupSuperseded,
}

/// A link the engine considered but ruled out, plus the first reason it hit.
/// Reasons are checked in the order defined on [IneligibilityReason]; ties
/// resolve to the first match (e.g. a Never link is always reported as
/// `never`, even if it also has high loss).
class IneligibleLink {
  final Link link;
  final IneligibilityReason reason;

  const IneligibleLink({required this.link, required this.reason});
}

/// The full output of one [PolicyEngine.evaluate] pass.
class PolicyDecision {
  /// Links that should receive new flows, in priority/weight order.
  final List<EligibleLink> eligible;

  /// Links that were considered but ruled out, with their first failure reason.
  final List<IneligibleLink> ineligible;

  /// Which group ([LinkPriority]) the engine settled on, or null when nothing
  /// is eligible. Used by the kill switch in Phase 4: when null && killSwitch
  /// is on, the transport stops listening.
  final LinkPriority? activeGroup;

  const PolicyDecision({
    required this.eligible,
    required this.ineligible,
    required this.activeGroup,
  });

  bool get hasEligible {
    return eligible.isNotEmpty;
  }
}

/// Health/eligibility thresholds. Tuned to Speedify's defaults so the OSS
/// clone feels familiar; exposed as a struct so a future settings screen can
/// let power users override the gates without forking the engine.
class PolicyEngineThresholds {
  final double maxLoss; // 0.0..1.0
  final double maxRttMs;

  /// Minimum weight floor applied during speed-cap normalization. Prevents a
  /// tiny secondary link from dropping below ~5 % share when it's the only
  /// other option in its group.
  final double minNormalizedShare;

  /// Maximum weight ceiling applied during speed-cap normalization. Prevents
  /// a single huge-capped link from monopolizing the group when other links
  /// are also healthy.
  final double maxNormalizedShare;

  const PolicyEngineThresholds({
    this.maxLoss = 0.30,
    this.maxRttMs = 1500.0,
    this.minNormalizedShare = 0.05,
    this.maxNormalizedShare = 0.95,
  });
}

/// Pure decision function: given the user's policy + the live metric snapshot
/// + (optionally) the current data-meter readings, returns the active set of
/// eligible links and their effective weights.
///
/// Stateless on purpose — the same inputs always produce the same output, so
/// the engine is safe to call from any thread and trivial to fuzz-test.
class PolicyEngine {
  final PolicyEngineThresholds thresholds;

  const PolicyEngine({
    this.thresholds = const PolicyEngineThresholds(),
  });

  /// Evaluate [policy] against [metrics].
  ///
  /// [dataUsedOverride] is consulted ahead of `link.dataUsedBytes` so the
  /// transport can pass the live counter from the data meter without having
  /// to write it back to the persisted [Link] on every byte.
  PolicyDecision evaluate({
    required Policy policy,
    Map<String, LinkMetric> metrics = const <String, LinkMetric>{},
    Map<String, int> dataUsedOverride = const <String, int>{},
  }) {
    List<IneligibleLink> ineligible = <IneligibleLink>[];
    Map<LinkPriority, List<Link>> eligibleByGroup = <LinkPriority, List<Link>>{
      LinkPriority.primary: <Link>[],
      LinkPriority.secondary: <Link>[],
      LinkPriority.backup: <Link>[],
    };

    for (Link link in policy.links) {
      if (link.priority == LinkPriority.never) {
        ineligible.add(IneligibleLink(
          link: link,
          reason: IneligibilityReason.never,
        ));
        continue;
      }
      if ((link.interfaceName == null || link.interfaceName!.isEmpty) &&
          (link.sourceAddress == null || link.sourceAddress!.isEmpty)) {
        ineligible.add(IneligibleLink(
          link: link,
          reason: IneligibilityReason.noSource,
        ));
        continue;
      }

      LinkMetric? metric = metrics[link.id];
      if (metric != null) {
        double? loss = metric.loss;
        if (loss != null && loss > thresholds.maxLoss) {
          ineligible.add(IneligibleLink(
            link: link,
            reason: IneligibilityReason.highLoss,
          ));
          continue;
        }
        double? rtt = metric.rttMs;
        if (rtt != null && rtt > thresholds.maxRttMs) {
          ineligible.add(IneligibleLink(
            link: link,
            reason: IneligibilityReason.highRtt,
          ));
          continue;
        }
      }

      int dataUsed = dataUsedOverride[link.id] ?? link.dataUsedBytes;
      if (link.dataCapBytes != null && dataUsed >= link.dataCapBytes!) {
        ineligible.add(IneligibleLink(
          link: link,
          reason: IneligibilityReason.dataCapExhausted,
        ));
        continue;
      }

      eligibleByGroup[link.priority]!.add(link);
    }

    LinkPriority? activeGroup;
    List<Link> activeMembers = const <Link>[];
    for (LinkPriority candidate in <LinkPriority>[
      LinkPriority.primary,
      LinkPriority.secondary,
      LinkPriority.backup,
    ]) {
      List<Link> members = eligibleByGroup[candidate]!;
      if (members.isNotEmpty) {
        activeGroup = candidate;
        activeMembers = members;
        break;
      }
    }

    // Links in eligible-but-superseded groups are demoted to the ineligible
    // list so the UI can render "primary fine but secondary group not in
    // use" semantics correctly.
    int groupRankFor(LinkPriority p) {
      switch (p) {
        case LinkPriority.primary:
          return 0;
        case LinkPriority.secondary:
          return 1;
        case LinkPriority.backup:
          return 2;
        case LinkPriority.never:
          return 3;
      }
    }

    if (activeGroup != null) {
      for (MapEntry<LinkPriority, List<Link>> entry
          in eligibleByGroup.entries) {
        if (entry.key == activeGroup) {
          continue;
        }
        for (Link link in entry.value) {
          ineligible.add(IneligibleLink(
            link: link,
            reason: IneligibilityReason.groupSuperseded,
          ));
        }
      }
    }

    if (activeGroup == null) {
      return PolicyDecision(
        eligible: const <EligibleLink>[],
        ineligible: ineligible,
        activeGroup: null,
      );
    }

    List<int> weights = _computeWeights(activeMembers);
    List<EligibleLink> eligible = <EligibleLink>[
      for (int i = 0; i < activeMembers.length; i++)
        EligibleLink(
          link: activeMembers[i],
          weight: weights[i],
          groupRank: groupRankFor(activeGroup),
          sourcePriority: activeMembers[i].priority,
        ),
    ];

    return PolicyDecision(
      eligible: eligible,
      ineligible: ineligible,
      activeGroup: activeGroup,
    );
  }

  /// Map per-link speed caps onto integer weights summing to roughly 100.
  ///
  /// Algorithm:
  /// * If no member has a speed cap, fall back to the user-configured
  ///   `link.weight` (integer, defaults to 1) — preserves the existing
  ///   weighted-RR behavior the legacy `WeightedRoundRobinDispatcher` ships.
  /// * If at least one cap is set, treat uncapped members as having an
  ///   infinite cap and capped members proportionally. Clamp each member's
  ///   normalized share into `[minNormalizedShare, maxNormalizedShare]`,
  ///   renormalize, then multiply by 100 and round to integers (minimum 1).
  List<int> _computeWeights(List<Link> members) {
    if (members.isEmpty) {
      return const <int>[];
    }
    bool anyCapped = members.any((Link l) => l.speedCapBps != null);
    if (!anyCapped) {
      return <int>[for (Link link in members) math.max(1, link.weight)];
    }
    // Replace "no cap" with a sentinel so it dominates the proportion math.
    // 10× the largest configured cap keeps integer arithmetic stable.
    int maxConfiguredCap = 0;
    for (Link link in members) {
      if (link.speedCapBps != null && link.speedCapBps! > maxConfiguredCap) {
        maxConfiguredCap = link.speedCapBps!;
      }
    }
    int uncappedSentinel =
        maxConfiguredCap > 0 ? maxConfiguredCap * 10 : 1000 * 1000 * 1000;
    List<double> raw = <double>[
      for (Link link in members)
        (link.speedCapBps ?? uncappedSentinel).toDouble(),
    ];
    double sum = raw.fold<double>(0.0, (double acc, double v) => acc + v);
    if (sum <= 0) {
      return <int>[for (Link _ in members) 1];
    }
    List<double> shares = <double>[
      for (double v in raw) (v / sum).clamp(
        thresholds.minNormalizedShare,
        thresholds.maxNormalizedShare,
      ),
    ];
    double normalize =
        shares.fold<double>(0.0, (double acc, double v) => acc + v);
    if (normalize <= 0) {
      return <int>[for (Link _ in members) 1];
    }
    List<int> weights = <int>[
      for (double s in shares) math.max(1, (s / normalize * 100.0).round()),
    ];
    return weights;
  }
}

/// Bridges [PolicyEngine] output to the legacy [WeightedRoundRobinDispatcher].
///
/// Phase 3 keeps the IP-level round-robin primitive intact and instead feeds
/// it `ResolvedWeightedAddress`es whose weight has already been overridden by
/// the policy engine's effective weight. The dispatcher therefore becomes a
/// thin wrapper over `PolicyEngine.eligible()` results — exactly what the
/// roadmap calls for, with no behavior change for callers that haven't yet
/// migrated to the engine.
///
/// [resolvedByLinkId] must be keyed by [Link.id]. Links missing a resolved
/// address are silently dropped: the resolver pass upstream already raised
/// whatever error those links would have caused. The output preserves the
/// order of [eligible], which is the order the engine emits (priority group
/// first, then internal stable order).
List<ResolvedWeightedAddress> eligibleToResolved(
  List<EligibleLink> eligible,
  Map<String, ResolvedWeightedAddress> resolvedByLinkId,
) {
  List<ResolvedWeightedAddress> result = <ResolvedWeightedAddress>[];
  for (EligibleLink slot in eligible) {
    ResolvedWeightedAddress? resolved = resolvedByLinkId[slot.link.id];
    if (resolved == null) {
      continue;
    }
    result.add(
      ResolvedWeightedAddress(
        label: resolved.label,
        weight: math.max(1, slot.weight),
        ipv4: resolved.ipv4,
        ipv6: resolved.ipv6,
      ),
    );
  }
  return result;
}
