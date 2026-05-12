import 'dart:io';

import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/link_metric.dart';
import 'package:arcane_dispatch/core/policy.dart';
import 'package:arcane_dispatch/core/weighted_address.dart';
import 'package:arcane_dispatch/policy/policy_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PolicyEngine.evaluate', () {
    test('emits primary group when at least one primary is healthy', () {
      Link p1 = _link('p1', priority: LinkPriority.primary);
      Link p2 = _link('p2', priority: LinkPriority.primary);
      Link s1 = _link('s1', priority: LinkPriority.secondary);
      Policy policy = Policy(links: <Link>[p1, p2, s1]);

      PolicyDecision decision =
          const PolicyEngine().evaluate(policy: policy);

      expect(decision.activeGroup, LinkPriority.primary);
      expect(
        decision.eligible.map((EligibleLink e) => e.link.id).toList(),
        <String>['p1', 'p2'],
      );
      expect(
        decision.ineligible.map((IneligibleLink i) => i.link.id).toList(),
        contains('s1'),
      );
      expect(
        decision.ineligible
            .firstWhere((IneligibleLink i) => i.link.id == 's1')
            .reason,
        IneligibilityReason.groupSuperseded,
      );
    });

    test('falls back to secondary when all primaries fail health gates', () {
      Link p1 = _link('p1', priority: LinkPriority.primary);
      Link s1 = _link('s1', priority: LinkPriority.secondary);
      Policy policy = Policy(links: <Link>[p1, s1]);

      Map<String, LinkMetric> metrics = <String, LinkMetric>{
        'p1': _metric('p1', loss: 0.50),
      };
      PolicyDecision decision =
          const PolicyEngine().evaluate(policy: policy, metrics: metrics);

      expect(decision.activeGroup, LinkPriority.secondary);
      expect(decision.eligible.single.link.id, 's1');
      expect(
        decision.ineligible
            .firstWhere((IneligibleLink i) => i.link.id == 'p1')
            .reason,
        IneligibilityReason.highLoss,
      );
    });

    test('falls back to backup when primaries and secondaries unavailable', () {
      Link p1 = _link('p1', priority: LinkPriority.primary);
      Link s1 = _link('s1', priority: LinkPriority.secondary);
      Link b1 = _link('b1', priority: LinkPriority.backup);
      Policy policy = Policy(links: <Link>[p1, s1, b1]);

      Map<String, LinkMetric> metrics = <String, LinkMetric>{
        'p1': _metric('p1', rttMs: 2000.0),
        's1': _metric('s1', loss: 0.40),
      };
      PolicyDecision decision =
          const PolicyEngine().evaluate(policy: policy, metrics: metrics);

      expect(decision.activeGroup, LinkPriority.backup);
      expect(decision.eligible.single.link.id, 'b1');
    });

    test('never-priority links are excluded with reason=never', () {
      Link p1 = _link('p1', priority: LinkPriority.primary);
      Link never = _link('x', priority: LinkPriority.never);
      Policy policy = Policy(links: <Link>[p1, never]);

      PolicyDecision decision =
          const PolicyEngine().evaluate(policy: policy);

      expect(decision.eligible.single.link.id, 'p1');
      expect(
        decision.ineligible.single.reason,
        IneligibilityReason.never,
      );
    });

    test('links without source address are excluded', () {
      Link broken = Link(
        id: 'broken',
        label: 'broken',
        priority: LinkPriority.primary,
      );
      Link ok = _link('ok', priority: LinkPriority.primary);
      Policy policy = Policy(links: <Link>[broken, ok]);

      PolicyDecision decision =
          const PolicyEngine().evaluate(policy: policy);

      expect(decision.eligible.single.link.id, 'ok');
      expect(
        decision.ineligible
            .firstWhere((IneligibleLink i) => i.link.id == 'broken')
            .reason,
        IneligibilityReason.noSource,
      );
    });

    test('data cap exhaustion drops link from primary group', () {
      Link p1 = _link('p1', priority: LinkPriority.primary, dataCapBytes: 1000);
      Link p2 = _link('p2', priority: LinkPriority.primary);
      Policy policy = Policy(links: <Link>[p1, p2]);

      PolicyDecision decision = const PolicyEngine().evaluate(
        policy: policy,
        dataUsedOverride: <String, int>{'p1': 1000},
      );

      expect(
        decision.eligible.map((EligibleLink e) => e.link.id).toList(),
        <String>['p2'],
      );
      expect(
        decision.ineligible
            .firstWhere((IneligibleLink i) => i.link.id == 'p1')
            .reason,
        IneligibilityReason.dataCapExhausted,
      );
    });

    test('speed caps normalize to integer weights summing to ~100', () {
      // 5 Mbps + 50 Mbps caps -> ~10/90 split (clamped at 5 % min / 95 % max).
      Link slow = _link(
        'slow',
        priority: LinkPriority.primary,
        speedCapBps: 5 * 1000 * 1000,
      );
      Link fast = _link(
        'fast',
        priority: LinkPriority.primary,
        speedCapBps: 50 * 1000 * 1000,
      );
      Policy policy = Policy(links: <Link>[slow, fast]);

      PolicyDecision decision =
          const PolicyEngine().evaluate(policy: policy);
      Map<String, int> weights = <String, int>{
        for (EligibleLink slot in decision.eligible) slot.link.id: slot.weight,
      };

      expect(weights['slow']! + weights['fast']!, inInclusiveRange(98, 102));
      expect(weights['fast'], greaterThan(weights['slow']!));
    });

    test('uncapped links fall back to Link.weight inside the group', () {
      Link a =
          _link('a', priority: LinkPriority.primary, weight: 1);
      Link b =
          _link('b', priority: LinkPriority.primary, weight: 4);
      Policy policy = Policy(links: <Link>[a, b]);

      PolicyDecision decision =
          const PolicyEngine().evaluate(policy: policy);

      Map<String, int> weights = <String, int>{
        for (EligibleLink slot in decision.eligible) slot.link.id: slot.weight,
      };
      expect(weights['a'], 1);
      expect(weights['b'], 4);
    });

    test('no eligible links -> activeGroup null and eligible empty', () {
      Link p1 = _link('p1', priority: LinkPriority.primary);
      Link s1 = _link('s1', priority: LinkPriority.secondary);
      Link b1 = _link('b1', priority: LinkPriority.backup);
      Policy policy = Policy(links: <Link>[p1, s1, b1]);

      Map<String, LinkMetric> metrics = <String, LinkMetric>{
        'p1': _metric('p1', rttMs: 99999.0),
        's1': _metric('s1', loss: 0.99),
        'b1': _metric('b1', loss: 0.99),
      };
      PolicyDecision decision =
          const PolicyEngine().evaluate(policy: policy, metrics: metrics);

      expect(decision.activeGroup, isNull);
      expect(decision.eligible, isEmpty);
      expect(decision.hasEligible, isFalse);
    });

    test('group order is preserved within an active group', () {
      Link a = _link('a', priority: LinkPriority.primary);
      Link b = _link('b', priority: LinkPriority.primary);
      Link c = _link('c', priority: LinkPriority.primary);
      Policy policy = Policy(links: <Link>[c, a, b]);

      PolicyDecision decision =
          const PolicyEngine().evaluate(policy: policy);

      expect(
        decision.eligible.map((EligibleLink e) => e.link.id).toList(),
        <String>['c', 'a', 'b'],
      );
    });
  });

  group('eligibleToResolved', () {
    test('overrides resolved weight with engine weight, preserves IPs', () {
      Link a = _link('a', priority: LinkPriority.primary, weight: 1);
      Link b = _link('b', priority: LinkPriority.primary, weight: 1);
      Policy policy = Policy(links: <Link>[a, b]);

      PolicyDecision decision =
          const PolicyEngine().evaluate(policy: policy);

      Map<String, ResolvedWeightedAddress> resolvedByLinkId =
          <String, ResolvedWeightedAddress>{
        'a': _resolved('a', InternetAddress('10.0.0.1')),
        'b': _resolved('b', InternetAddress('10.0.0.2')),
      };
      List<ResolvedWeightedAddress> result =
          eligibleToResolved(decision.eligible, resolvedByLinkId);

      expect(result, hasLength(2));
      // Engine weights stayed at 1 because no caps; ensure pass-through is
      // stable.
      expect(result.first.weight, isPositive);
      expect(result.first.ipv4?.address, '10.0.0.1');
      expect(result.last.ipv4?.address, '10.0.0.2');
    });

    test('drops eligible links missing from resolved map', () {
      Link a = _link('a', priority: LinkPriority.primary);
      Link b = _link('b', priority: LinkPriority.primary);
      Policy policy = Policy(links: <Link>[a, b]);

      PolicyDecision decision =
          const PolicyEngine().evaluate(policy: policy);

      Map<String, ResolvedWeightedAddress> resolvedByLinkId =
          <String, ResolvedWeightedAddress>{
        'a': _resolved('a', InternetAddress('10.0.0.1')),
        // 'b' deliberately missing.
      };
      List<ResolvedWeightedAddress> result =
          eligibleToResolved(decision.eligible, resolvedByLinkId);

      expect(result, hasLength(1));
      expect(result.single.ipv4?.address, '10.0.0.1');
    });

    test('weight floor is 1 even when engine weight rounds to 0', () {
      EligibleLink slot = const EligibleLink(
        link: Link(
          id: 'a',
          label: 'a',
          interfaceName: 'en0',
        ),
        weight: 0,
        groupRank: 0,
        sourcePriority: LinkPriority.primary,
      );
      Map<String, ResolvedWeightedAddress> resolvedByLinkId =
          <String, ResolvedWeightedAddress>{
        'a': _resolved('a', InternetAddress('10.0.0.1')),
      };
      List<ResolvedWeightedAddress> result = eligibleToResolved(
        <EligibleLink>[slot],
        resolvedByLinkId,
      );

      expect(result.single.weight, 1);
    });
  });
}

Link _link(
  String id, {
  LinkPriority priority = LinkPriority.primary,
  int weight = 1,
  int? speedCapBps,
  int? dataCapBytes,
}) {
  return Link(
    id: id,
    label: id,
    interfaceName: 'en$id',
    priority: priority,
    weight: weight,
    speedCapBps: speedCapBps,
    dataCapBytes: dataCapBytes,
  );
}

LinkMetric _metric(String id, {double? rttMs, double? loss}) {
  return LinkMetric(
    linkId: id,
    capturedAt: DateTime(2026, 1, 1),
    rttMs: rttMs,
    loss: loss,
  );
}

ResolvedWeightedAddress _resolved(String label, InternetAddress addr) {
  return ResolvedWeightedAddress(
    label: label,
    weight: 1,
    ipv4: addr.type == InternetAddressType.IPv4 ? addr : null,
    ipv6: addr.type == InternetAddressType.IPv6 ? addr : null,
  );
}
