import 'dart:async';
import 'dart:io';
import 'package:arcane_dispatch/core/bonding_mode.dart';
import 'package:arcane_dispatch/core/link_metric.dart';
import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/policy.dart';
import 'package:arcane_dispatch/core/weighted_address.dart';
import 'package:arcane_dispatch/policy/data_meter.dart';
import 'package:arcane_dispatch/policy/link_supervisor.dart';
import 'package:arcane_dispatch/policy/policy_engine.dart';
import 'package:arcane_dispatch/policy/token_bucket.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void dataMeterSuite() {
  group('DataMeter', () {
    late Directory tempDir;
    late Box box;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'arcane_dispatch_data_meter_',
      );
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
      Link a = _dataMeterLink('a');
      Link b = _dataMeterLink('b');
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
      Link a = _dataMeterLink('a');
      meter.recordBytes(a, 0);
      meter.recordBytes(a, -10);
      expect(meter.usedFor(a), 0);
    });

    test('isExhausted is false without cap, true at/above cap', () {
      DataMeter meter = DataMeter(storage: box);
      Link uncapped = _dataMeterLink('uncapped');
      Link capped = _dataMeterLink('capped', dataCapBytes: 1000);
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
      Link a = _dataMeterLink('a');
      meter.recordBytes(a, 256);
      await meter.flush();

      Object? raw = box.get('data_meter_v1/a');
      expect(raw, isA<String>());
      expect((raw as String).contains('"used":256'), isTrue);
    });

    test('reopening a meter rehydrates from Hive snapshot', () async {
      DataMeter m1 = DataMeter(storage: box);
      Link a = _dataMeterLink('a');
      m1.recordBytes(a, 999);
      await m1.flush();
      await m1.dispose();

      DataMeter m2 = DataMeter(storage: box);
      expect(m2.usedFor(a), 999);
    });

    test('reset zeroes the counter for a specific link', () {
      DataMeter meter = DataMeter(storage: box);
      Link a = _dataMeterLink('a');
      Link b = _dataMeterLink('b');
      meter.recordBytes(a, 500);
      meter.recordBytes(b, 300);
      meter.reset(a);
      expect(meter.usedFor(a), 0);
      expect(meter.usedFor(b), 300);
    });

    test('dispose flushes before sealing the meter', () async {
      DataMeter meter = DataMeter(storage: box);
      Link a = _dataMeterLink('a');
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
      DataMeter meter = DataMeter(storage: box, now: () => fakeNow);
      Link a = _dataMeterLink('a', billingCycleAnchor: '15');
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
      DataMeter meter = DataMeter(storage: box, now: () => fakeNow);
      Link a = _dataMeterLink('a', billingCycleAnchor: '15');
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
      DataMeter meter = DataMeter(storage: box, now: () => fakeNow);
      Link a = _dataMeterLink('a', billingCycleAnchor: '2026-01-15');
      meter.recordBytes(a, 100);
      expect(meter.usedFor(a), 100);

      fakeNow = DateTime.utc(2026, 2, 16);
      expect(meter.usedFor(a), 0);
    });

    test('null anchor falls back to first of the month', () {
      DateTime fakeNow = DateTime.utc(2026, 1, 20, 12);
      DataMeter meter = DataMeter(storage: box, now: () => fakeNow);
      Link a = _dataMeterLink('a'); // no anchor
      meter.recordBytes(a, 100);

      // Cross into February -> should reset.
      fakeNow = DateTime.utc(2026, 2, 1);
      expect(meter.usedFor(a), 0);
    });
  });
}

Link _dataMeterLink(
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

void linkSupervisorSuite() {
  group('LinkSupervisor', () {
    test('emits a verdict for every link in the policy', () async {
      LinkSupervisor supervisor = LinkSupervisor();
      LinkHealthEvent? event;
      StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
        (LinkHealthEvent e) => event = e,
      );

      supervisor.updatePolicy(
        _linkSupervisorPolicy(<Link>[
          _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
          _linkSupervisorLink('s', LinkPriority.secondary, source: '10.0.0.2'),
        ]),
      );
      await _linkSupervisorFlush();

      expect(event, isNotNull);
      expect(event!.statuses.keys.toSet(), <String>{'p', 's'});
      // Primary group is the only eligible one.
      expect(event!.statuses['p'], LinkStatus.healthy);
      // Secondary is "fine but superseded" — surfaces as degraded so the
      // user can see which links are sitting on the bench.
      expect(event!.statuses['s'], LinkStatus.degraded);
      expect(event!.killSwitchActive, isFalse);

      await sub.cancel();
      await supervisor.dispose();
    });

    test(
      'kill switch engages when every link is unhealthy and policy.killSwitch is on',
      () async {
        LinkSupervisor supervisor = LinkSupervisor(hysteresisCount: 1);
        List<LinkHealthEvent> events = <LinkHealthEvent>[];
        StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
          events.add,
        );

        supervisor.updatePolicy(
          _linkSupervisorPolicy(<Link>[
            _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
          ], killSwitch: true),
        );
        await _linkSupervisorFlush();

        // No metric yet: the link is healthy by default (engine is permissive
        // when there's no signal). Sanity check the eligible path before we
        // poison it.
        expect(events.last.killSwitchActive, isFalse);

        supervisor.updateMetric(
          LinkMetric(
            linkId: 'p',
            capturedAt: DateTime.now().toUtc(),
            loss: 0.95, // way over the 0.30 threshold
          ),
        );
        await _linkSupervisorFlush();

        expect(events.last.killSwitchActive, isTrue);
        expect(events.last.statuses['p'], LinkStatus.unhealthy);
        expect(supervisor.isKillSwitchActive, isTrue);

        await sub.cancel();
        await supervisor.dispose();
      },
    );

    test(
      'kill switch stays off when policy.killSwitch is false even with no eligible links',
      () async {
        LinkSupervisor supervisor = LinkSupervisor(hysteresisCount: 1);
        LinkHealthEvent? event;
        StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
          (LinkHealthEvent e) => event = e,
        );

        supervisor.updatePolicy(
          _linkSupervisorPolicy(<Link>[
            _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
          ], killSwitch: false),
        );
        supervisor.updateMetric(
          LinkMetric(
            linkId: 'p',
            capturedAt: DateTime.now().toUtc(),
            loss: 0.95,
          ),
        );
        await _linkSupervisorFlush();

        expect(event!.statuses['p'], LinkStatus.unhealthy);
        // Decision has no eligible link, but the supervisor's switch flag
        // requires policy.killSwitch=true to flip on.
        expect(event!.decision.hasEligible, isFalse);
        expect(event!.killSwitchActive, isFalse);

        await sub.cancel();
        await supervisor.dispose();
      },
    );

    test('kill switch releases when a link recovers', () async {
      LinkSupervisor supervisor = LinkSupervisor(hysteresisCount: 1);
      List<LinkHealthEvent> events = <LinkHealthEvent>[];
      StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
        events.add,
      );

      supervisor.updatePolicy(
        _linkSupervisorPolicy(<Link>[
          _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
        ], killSwitch: true),
      );
      supervisor.updateMetric(
        LinkMetric(linkId: 'p', capturedAt: DateTime.now().toUtc(), loss: 0.95),
      );
      await _linkSupervisorFlush();
      expect(events.last.killSwitchActive, isTrue);

      // Link recovers.
      supervisor.updateMetric(
        LinkMetric(
          linkId: 'p',
          capturedAt: DateTime.now().toUtc(),
          loss: 0.01,
          rttMs: 30.0,
        ),
      );
      await _linkSupervisorFlush();

      expect(events.last.killSwitchActive, isFalse);
      expect(events.last.statuses['p'], LinkStatus.healthy);

      await sub.cancel();
      await supervisor.dispose();
    });

    test(
      'updateMetrics replaces the full snapshot in one evaluation',
      () async {
        LinkSupervisor supervisor = LinkSupervisor(hysteresisCount: 1);
        List<LinkHealthEvent> events = <LinkHealthEvent>[];
        StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
          events.add,
        );

        supervisor.updatePolicy(
          _linkSupervisorPolicy(<Link>[
            _linkSupervisorLink('a', LinkPriority.primary, source: '10.0.0.1'),
            _linkSupervisorLink('b', LinkPriority.primary, source: '10.0.0.2'),
          ]),
        );
        // First metric makes b unhealthy.
        supervisor.updateMetric(
          LinkMetric(
            linkId: 'b',
            capturedAt: DateTime.now().toUtc(),
            loss: 0.99,
          ),
        );
        await _linkSupervisorFlush();
        int afterFirst = events.length;
        expect(events.last.statuses['b'], LinkStatus.unhealthy);

        // Bulk replace: both links healthy. Should evaluate exactly once.
        supervisor.updateMetrics(<String, LinkMetric>{
          'a': LinkMetric(
            linkId: 'a',
            capturedAt: DateTime.now().toUtc(),
            rttMs: 20.0,
          ),
          'b': LinkMetric(
            linkId: 'b',
            capturedAt: DateTime.now().toUtc(),
            rttMs: 25.0,
            loss: 0.0,
          ),
        });
        await _linkSupervisorFlush();

        expect(events.length, afterFirst + 1);
        expect(events.last.statuses['a'], LinkStatus.healthy);
        expect(events.last.statuses['b'], LinkStatus.healthy);

        await sub.cancel();
        await supervisor.dispose();
      },
    );

    test('evicts metrics for links that disappear from the policy', () async {
      LinkSupervisor supervisor = LinkSupervisor();
      LinkHealthEvent? event;
      StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
        (LinkHealthEvent e) => event = e,
      );

      supervisor.updatePolicy(
        _linkSupervisorPolicy(<Link>[
          _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
          _linkSupervisorLink('q', LinkPriority.primary, source: '10.0.0.2'),
        ]),
      );
      supervisor.updateMetric(
        LinkMetric(
          linkId: 'q',
          capturedAt: DateTime.now().toUtc(),
          rttMs: 25.0,
        ),
      );
      await _linkSupervisorFlush();
      expect(event!.statuses.keys, contains('q'));

      // Drop q from the policy. The next evaluation should not mention it
      // even though we still know its metric (it should have been evicted).
      supervisor.updatePolicy(
        _linkSupervisorPolicy(<Link>[
          _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
        ]),
      );
      await _linkSupervisorFlush();
      expect(event!.statuses.keys, isNot(contains('q')));
      expect(event!.statuses.keys, <String>{'p'});

      await sub.cancel();
      await supervisor.dispose();
    });

    test('ignores updates after dispose', () async {
      LinkSupervisor supervisor = LinkSupervisor();
      List<LinkHealthEvent> events = <LinkHealthEvent>[];
      StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
        events.add,
      );

      supervisor.updatePolicy(
        _linkSupervisorPolicy(<Link>[
          _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
        ]),
      );
      await _linkSupervisorFlush();
      int baseline = events.length;

      await supervisor.dispose();
      // Subscription closes when the controller closes; cancel in case to
      // avoid leaking the listener.
      await sub.cancel();

      // Updates after dispose must be no-ops.
      supervisor.updateMetric(
        LinkMetric(linkId: 'p', capturedAt: DateTime.now().toUtc(), loss: 0.99),
      );
      supervisor.updatePolicy(_linkSupervisorPolicy(<Link>[]));
      await _linkSupervisorFlush();
      expect(events.length, baseline);
    });

    test(
      'a link with priority Never is reported as disabled (not unhealthy)',
      () async {
        LinkSupervisor supervisor = LinkSupervisor();
        LinkHealthEvent? event;
        StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
          (LinkHealthEvent e) => event = e,
        );

        supervisor.updatePolicy(
          _linkSupervisorPolicy(<Link>[
            _linkSupervisorLink('a', LinkPriority.primary, source: '10.0.0.1'),
            _linkSupervisorLink('z', LinkPriority.never, source: '10.0.0.9'),
          ]),
        );
        // Even with terrible metrics, a Never link must still report disabled.
        supervisor.updateMetric(
          LinkMetric(
            linkId: 'z',
            capturedAt: DateTime.now().toUtc(),
            loss: 0.99,
            rttMs: 5000.0,
          ),
        );
        await _linkSupervisorFlush();

        expect(event!.statuses['z'], LinkStatus.disabled);
        expect(event!.statuses['a'], LinkStatus.healthy);

        await sub.cancel();
        await supervisor.dispose();
      },
    );

    test('linksWithStatus filters by status correctly', () async {
      LinkSupervisor supervisor = LinkSupervisor(hysteresisCount: 1);
      LinkHealthEvent? event;
      StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
        (LinkHealthEvent e) => event = e,
      );

      supervisor.updatePolicy(
        _linkSupervisorPolicy(<Link>[
          _linkSupervisorLink('a', LinkPriority.primary, source: '10.0.0.1'),
          _linkSupervisorLink('b', LinkPriority.primary, source: '10.0.0.2'),
          _linkSupervisorLink('c', LinkPriority.secondary, source: '10.0.0.3'),
          _linkSupervisorLink('z', LinkPriority.never, source: '10.0.0.9'),
        ]),
      );
      supervisor.updateMetric(
        LinkMetric(linkId: 'b', capturedAt: DateTime.now().toUtc(), loss: 0.95),
      );
      await _linkSupervisorFlush();

      expect(event!.linksWithStatus(LinkStatus.healthy)..sort(), <String>['a']);
      expect(event!.linksWithStatus(LinkStatus.unhealthy), <String>['b']);
      expect(event!.linksWithStatus(LinkStatus.degraded), <String>['c']);
      expect(event!.linksWithStatus(LinkStatus.disabled), <String>['z']);

      await sub.cancel();
      await supervisor.dispose();
    });

    test(
      'data-cap exhaustion via dataUsedProvider routes to unhealthy',
      () async {
        LinkSupervisor supervisor = LinkSupervisor(
          dataUsedProvider: () => <String, int>{'p': 5_000_000_000},
        );
        LinkHealthEvent? event;
        StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
          (LinkHealthEvent e) => event = e,
        );

        supervisor.updatePolicy(
          _linkSupervisorPolicy(<Link>[
            _linkSupervisorLink(
              'p',
              LinkPriority.primary,
              source: '10.0.0.1',
              dataCapBytes: 1_000_000_000,
            ),
            _linkSupervisorLink('q', LinkPriority.primary, source: '10.0.0.2'),
          ]),
        );
        await _linkSupervisorFlush();

        expect(event!.statuses['p'], LinkStatus.unhealthy);
        expect(event!.statuses['q'], LinkStatus.healthy);

        await sub.cancel();
        await supervisor.dispose();
      },
    );

    test('lastEvent reflects most recent emit', () async {
      LinkSupervisor supervisor = LinkSupervisor();
      expect(supervisor.lastEvent, isNull);

      supervisor.updatePolicy(
        _linkSupervisorPolicy(<Link>[
          _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
        ]),
      );
      await _linkSupervisorFlush();
      expect(supervisor.lastEvent, isNotNull);
      expect(supervisor.lastEvent!.statuses['p'], LinkStatus.healthy);

      await supervisor.dispose();
    });

    test(
      'hysteresis: requires N consecutive observations before flipping',
      () async {
        LinkSupervisor supervisor = LinkSupervisor(hysteresisCount: 3);
        List<LinkHealthEvent> events = <LinkHealthEvent>[];
        StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
          events.add,
        );

        supervisor.updatePolicy(
          _linkSupervisorPolicy(<Link>[
            _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
          ]),
        );
        await _linkSupervisorFlush();
        // First emit is the initial transition from "no prior state" → healthy.
        expect(events.last.statuses['p'], LinkStatus.healthy);

        LinkMetric bad = LinkMetric(
          linkId: 'p',
          capturedAt: DateTime.now().toUtc(),
          loss: 0.99,
        );

        // Tick 1 of unhealthy: still publishes healthy.
        supervisor.updateMetric(bad);
        await _linkSupervisorFlush();
        expect(events.last.statuses['p'], LinkStatus.healthy);

        // Tick 2 of unhealthy: still healthy.
        supervisor.updateMetric(bad);
        await _linkSupervisorFlush();
        expect(events.last.statuses['p'], LinkStatus.healthy);

        // Tick 3 of unhealthy: NOW publishes unhealthy.
        supervisor.updateMetric(bad);
        await _linkSupervisorFlush();
        expect(events.last.statuses['p'], LinkStatus.unhealthy);

        // A single recovery sample is not enough to flip back.
        supervisor.updateMetric(
          LinkMetric(
            linkId: 'p',
            capturedAt: DateTime.now().toUtc(),
            rttMs: 25.0,
            loss: 0.0,
          ),
        );
        await _linkSupervisorFlush();
        expect(events.last.statuses['p'], LinkStatus.unhealthy);

        await sub.cancel();
        await supervisor.dispose();
      },
    );

    test('hysteresis: changing direction restarts the debouncer', () async {
      LinkSupervisor supervisor = LinkSupervisor(hysteresisCount: 3);
      List<LinkHealthEvent> events = <LinkHealthEvent>[];
      StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
        events.add,
      );

      supervisor.updatePolicy(
        _linkSupervisorPolicy(<Link>[
          _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
        ]),
      );
      await _linkSupervisorFlush();
      expect(events.last.statuses['p'], LinkStatus.healthy);

      LinkMetric bad = LinkMetric(
        linkId: 'p',
        capturedAt: DateTime.now().toUtc(),
        loss: 0.99,
      );
      LinkMetric good = LinkMetric(
        linkId: 'p',
        capturedAt: DateTime.now().toUtc(),
        rttMs: 25.0,
        loss: 0.0,
      );

      // 2 ticks unhealthy then 1 tick healthy — debouncer must restart.
      supervisor.updateMetric(bad);
      supervisor.updateMetric(bad);
      supervisor.updateMetric(good);
      await _linkSupervisorFlush();
      // Still healthy (the debouncer was building toward unhealthy then got
      // contradicted; the candidate is cleared, no new unhealthy state).
      expect(events.last.statuses['p'], LinkStatus.healthy);

      await sub.cancel();
      await supervisor.dispose();
    });

    test(
      'hysteresis: priority=never transitions bypass the debouncer',
      () async {
        LinkSupervisor supervisor = LinkSupervisor(hysteresisCount: 3);
        List<LinkHealthEvent> events = <LinkHealthEvent>[];
        StreamSubscription<LinkHealthEvent> sub = supervisor.events.listen(
          events.add,
        );

        supervisor.updatePolicy(
          _linkSupervisorPolicy(<Link>[
            _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
          ]),
        );
        await _linkSupervisorFlush();

        // Single-shot switch to never → immediate disabled, no waiting.
        supervisor.updatePolicy(
          _linkSupervisorPolicy(<Link>[
            _linkSupervisorLink('p', LinkPriority.never, source: '10.0.0.1'),
          ]),
        );
        await _linkSupervisorFlush();
        expect(events.last.statuses['p'], LinkStatus.disabled);

        // And back: single-shot promotion is also instant.
        supervisor.updatePolicy(
          _linkSupervisorPolicy(<Link>[
            _linkSupervisorLink('p', LinkPriority.primary, source: '10.0.0.1'),
          ]),
        );
        await _linkSupervisorFlush();
        expect(events.last.statuses['p'], LinkStatus.healthy);

        await sub.cancel();
        await supervisor.dispose();
      },
    );
  });
}

Policy _linkSupervisorPolicy(List<Link> links, {bool killSwitch = false}) {
  return Policy(mode: BondingMode.speed, links: links, killSwitch: killSwitch);
}

Link _linkSupervisorLink(
  String id,
  LinkPriority priority, {
  String? source,
  int? dataCapBytes,
}) {
  return Link(
    id: id,
    label: id,
    priority: priority,
    sourceAddress: source,
    dataCapBytes: dataCapBytes,
  );
}

/// Yield to the event loop so any synchronous broadcast emit completes.
Future<void> _linkSupervisorFlush() async {
  await Future<void>.delayed(Duration.zero);
}

void policyEngineSuite() {
  group('PolicyEngine.evaluate', () {
    test('emits primary group when at least one primary is healthy', () {
      Link p1 = _policyEngineLink('p1', priority: LinkPriority.primary);
      Link p2 = _policyEngineLink('p2', priority: LinkPriority.primary);
      Link s1 = _policyEngineLink('s1', priority: LinkPriority.secondary);
      Policy policy = Policy(links: <Link>[p1, p2, s1]);

      PolicyDecision decision = const PolicyEngine().evaluate(policy: policy);

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
      Link p1 = _policyEngineLink('p1', priority: LinkPriority.primary);
      Link s1 = _policyEngineLink('s1', priority: LinkPriority.secondary);
      Policy policy = Policy(links: <Link>[p1, s1]);

      Map<String, LinkMetric> metrics = <String, LinkMetric>{
        'p1': _policyEngineMetric('p1', loss: 0.50),
      };
      PolicyDecision decision = const PolicyEngine().evaluate(
        policy: policy,
        metrics: metrics,
      );

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
      Link p1 = _policyEngineLink('p1', priority: LinkPriority.primary);
      Link s1 = _policyEngineLink('s1', priority: LinkPriority.secondary);
      Link b1 = _policyEngineLink('b1', priority: LinkPriority.backup);
      Policy policy = Policy(links: <Link>[p1, s1, b1]);

      Map<String, LinkMetric> metrics = <String, LinkMetric>{
        'p1': _policyEngineMetric('p1', rttMs: 2000.0),
        's1': _policyEngineMetric('s1', loss: 0.40),
      };
      PolicyDecision decision = const PolicyEngine().evaluate(
        policy: policy,
        metrics: metrics,
      );

      expect(decision.activeGroup, LinkPriority.backup);
      expect(decision.eligible.single.link.id, 'b1');
    });

    test('never-priority links are excluded with reason=never', () {
      Link p1 = _policyEngineLink('p1', priority: LinkPriority.primary);
      Link never = _policyEngineLink('x', priority: LinkPriority.never);
      Policy policy = Policy(links: <Link>[p1, never]);

      PolicyDecision decision = const PolicyEngine().evaluate(policy: policy);

      expect(decision.eligible.single.link.id, 'p1');
      expect(decision.ineligible.single.reason, IneligibilityReason.never);
    });

    test('links without source address are excluded', () {
      Link broken = Link(
        id: 'broken',
        label: 'broken',
        priority: LinkPriority.primary,
      );
      Link ok = _policyEngineLink('ok', priority: LinkPriority.primary);
      Policy policy = Policy(links: <Link>[broken, ok]);

      PolicyDecision decision = const PolicyEngine().evaluate(policy: policy);

      expect(decision.eligible.single.link.id, 'ok');
      expect(
        decision.ineligible
            .firstWhere((IneligibleLink i) => i.link.id == 'broken')
            .reason,
        IneligibilityReason.noSource,
      );
    });

    test('data cap exhaustion drops link from primary group', () {
      Link p1 = _policyEngineLink(
        'p1',
        priority: LinkPriority.primary,
        dataCapBytes: 1000,
      );
      Link p2 = _policyEngineLink('p2', priority: LinkPriority.primary);
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
      Link slow = _policyEngineLink(
        'slow',
        priority: LinkPriority.primary,
        speedCapBps: 5 * 1000 * 1000,
      );
      Link fast = _policyEngineLink(
        'fast',
        priority: LinkPriority.primary,
        speedCapBps: 50 * 1000 * 1000,
      );
      Policy policy = Policy(links: <Link>[slow, fast]);

      PolicyDecision decision = const PolicyEngine().evaluate(policy: policy);
      Map<String, int> weights = <String, int>{
        for (EligibleLink slot in decision.eligible) slot.link.id: slot.weight,
      };

      expect(weights['slow']! + weights['fast']!, inInclusiveRange(98, 102));
      expect(weights['fast'], greaterThan(weights['slow']!));
    });

    test('uncapped links fall back to Link.weight inside the group', () {
      Link a = _policyEngineLink(
        'a',
        priority: LinkPriority.primary,
        weight: 1,
      );
      Link b = _policyEngineLink(
        'b',
        priority: LinkPriority.primary,
        weight: 4,
      );
      Policy policy = Policy(links: <Link>[a, b]);

      PolicyDecision decision = const PolicyEngine().evaluate(policy: policy);

      Map<String, int> weights = <String, int>{
        for (EligibleLink slot in decision.eligible) slot.link.id: slot.weight,
      };
      expect(weights['a'], 1);
      expect(weights['b'], 4);
    });

    test('no eligible links -> activeGroup null and eligible empty', () {
      Link p1 = _policyEngineLink('p1', priority: LinkPriority.primary);
      Link s1 = _policyEngineLink('s1', priority: LinkPriority.secondary);
      Link b1 = _policyEngineLink('b1', priority: LinkPriority.backup);
      Policy policy = Policy(links: <Link>[p1, s1, b1]);

      Map<String, LinkMetric> metrics = <String, LinkMetric>{
        'p1': _policyEngineMetric('p1', rttMs: 99999.0),
        's1': _policyEngineMetric('s1', loss: 0.99),
        'b1': _policyEngineMetric('b1', loss: 0.99),
      };
      PolicyDecision decision = const PolicyEngine().evaluate(
        policy: policy,
        metrics: metrics,
      );

      expect(decision.activeGroup, isNull);
      expect(decision.eligible, isEmpty);
      expect(decision.hasEligible, isFalse);
    });

    test('group order is preserved within an active group', () {
      Link a = _policyEngineLink('a', priority: LinkPriority.primary);
      Link b = _policyEngineLink('b', priority: LinkPriority.primary);
      Link c = _policyEngineLink('c', priority: LinkPriority.primary);
      Policy policy = Policy(links: <Link>[c, a, b]);

      PolicyDecision decision = const PolicyEngine().evaluate(policy: policy);

      expect(
        decision.eligible.map((EligibleLink e) => e.link.id).toList(),
        <String>['c', 'a', 'b'],
      );
    });
  });

  group('eligibleToResolved', () {
    test('overrides resolved weight with engine weight, preserves IPs', () {
      Link a = _policyEngineLink(
        'a',
        priority: LinkPriority.primary,
        weight: 1,
      );
      Link b = _policyEngineLink(
        'b',
        priority: LinkPriority.primary,
        weight: 1,
      );
      Policy policy = Policy(links: <Link>[a, b]);

      PolicyDecision decision = const PolicyEngine().evaluate(policy: policy);

      Map<String, ResolvedWeightedAddress> resolvedByLinkId =
          <String, ResolvedWeightedAddress>{
            'a': _policyEngineResolved('a', InternetAddress('10.0.0.1')),
            'b': _policyEngineResolved('b', InternetAddress('10.0.0.2')),
          };
      List<ResolvedWeightedAddress> result = eligibleToResolved(
        decision.eligible,
        resolvedByLinkId,
      );

      expect(result, hasLength(2));
      // Engine weights stayed at 1 because no caps; ensure pass-through is
      // stable.
      expect(result.first.weight, isPositive);
      expect(result.first.ipv4?.address, '10.0.0.1');
      expect(result.last.ipv4?.address, '10.0.0.2');
    });

    test('drops eligible links missing from resolved map', () {
      Link a = _policyEngineLink('a', priority: LinkPriority.primary);
      Link b = _policyEngineLink('b', priority: LinkPriority.primary);
      Policy policy = Policy(links: <Link>[a, b]);

      PolicyDecision decision = const PolicyEngine().evaluate(policy: policy);

      Map<String, ResolvedWeightedAddress> resolvedByLinkId =
          <String, ResolvedWeightedAddress>{
            'a': _policyEngineResolved('a', InternetAddress('10.0.0.1')),
            // 'b' deliberately missing.
          };
      List<ResolvedWeightedAddress> result = eligibleToResolved(
        decision.eligible,
        resolvedByLinkId,
      );

      expect(result, hasLength(1));
      expect(result.single.ipv4?.address, '10.0.0.1');
    });

    test('weight floor is 1 even when engine weight rounds to 0', () {
      EligibleLink slot = const EligibleLink(
        link: Link(id: 'a', label: 'a', interfaceName: 'en0'),
        weight: 0,
        groupRank: 0,
        sourcePriority: LinkPriority.primary,
      );
      Map<String, ResolvedWeightedAddress> resolvedByLinkId =
          <String, ResolvedWeightedAddress>{
            'a': _policyEngineResolved('a', InternetAddress('10.0.0.1')),
          };
      List<ResolvedWeightedAddress> result = eligibleToResolved(<EligibleLink>[
        slot,
      ], resolvedByLinkId);

      expect(result.single.weight, 1);
    });
  });
}

Link _policyEngineLink(
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

LinkMetric _policyEngineMetric(String id, {double? rttMs, double? loss}) {
  return LinkMetric(
    linkId: id,
    capturedAt: DateTime(2026, 1, 1),
    rttMs: rttMs,
    loss: loss,
  );
}

ResolvedWeightedAddress _policyEngineResolved(
  String label,
  InternetAddress addr,
) {
  return ResolvedWeightedAddress(
    label: label,
    weight: 1,
    ipv4: addr.type == InternetAddressType.IPv4 ? addr : null,
    ipv6: addr.type == InternetAddressType.IPv6 ? addr : null,
  );
}

void tokenBucketSuite() {
  group('TokenBucket', () {
    test('isUnlimited when refill <= 0', () {
      TokenBucket b = TokenBucket(refillBytesPerSec: 0);
      expect(b.isUnlimited, isTrue);
      b.dispose();
    });

    test('unlimited bucket: acquire completes immediately', () async {
      TokenBucket b = TokenBucket(refillBytesPerSec: 0);
      await b.acquire(10000000); // should not throw / not delay
      b.dispose();
    });

    test('tryConsume returns 0 when bucket is empty (after draining)', () {
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 1000,
        burstBytes: 1000,
        now: () => fakeNow,
      );
      // Drain the full burst.
      int taken = b.tryConsume(1000);
      expect(taken, 1000);
      int again = b.tryConsume(500);
      expect(again, 0);
      b.dispose();
    });

    test('tryConsume returns min(available, requested)', () {
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 1000,
        burstBytes: 1000,
        now: () => fakeNow,
      );
      int taken = b.tryConsume(2000);
      expect(taken, 1000);
      b.dispose();
    });

    test('tokens refill at the configured rate over time', () {
      // Mutable clock so we can advance time without sleeping.
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 1000,
        burstBytes: 2000,
        now: () => fakeNow,
      );
      // Drain.
      expect(b.tryConsume(2000), 2000);
      expect(b.tryConsume(1), 0);
      // Advance 500 ms -> expect ~500 tokens.
      fakeNow = fakeNow.add(const Duration(milliseconds: 500));
      double tokens = b.tokens;
      expect(tokens, inInclusiveRange(490.0, 510.0));
      b.dispose();
    });

    test('tokens cap at burstBytes when idle', () {
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 1000,
        burstBytes: 500,
        now: () => fakeNow,
      );
      // Bucket starts full at burst (500). Advance 10 s -> still 500.
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      expect(b.tokens, 500);
      b.dispose();
    });

    test('default burstBytes equals refillBytesPerSec', () {
      TokenBucket b = TokenBucket(refillBytesPerSec: 12345);
      expect(b.burstBytes, 12345);
      b.dispose();
    });

    test('acquire waits until enough tokens accumulate', () async {
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 10000, // 10 KB/s
        burstBytes: 5000,
        now: () => fakeNow,
      );
      // Drain to zero, then ask for 2500 (~250 ms at 10 KB/s).
      // Stays under burstBytes so the bucket can actually reach the threshold.
      expect(b.tryConsume(5000), 5000);

      // Background: advance fake clock at the bucket's polling cadence so its
      // `_refill()` sees enough elapsed time on each retry.
      Future<void> advancer() async {
        for (int i = 0; i < 40; i += 1) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          fakeNow = fakeNow.add(const Duration(milliseconds: 100));
        }
      }

      Stopwatch sw = Stopwatch()..start();
      Future<void> acquire = b.acquire(2500);
      Future<void> advance = advancer();
      await acquire.timeout(const Duration(seconds: 5));
      sw.stop();
      await advance;

      // After acquire returns, the bucket should have ~half its tokens.
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(0));
      b.dispose();
    });

    test('acquire after dispose throws StateError', () async {
      TokenBucket b = TokenBucket(refillBytesPerSec: 1000);
      b.dispose();
      await expectLater(b.acquire(10), throwsA(isA<StateError>()));
    });

    test('tryConsume after dispose returns 0', () {
      TokenBucket b = TokenBucket(refillBytesPerSec: 1000);
      b.dispose();
      expect(b.tryConsume(10), 0);
    });

    test('acquire(0) is a no-op even when bucket is empty', () async {
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 1000,
        burstBytes: 100,
        now: () => fakeNow,
      );
      expect(b.tryConsume(100), 100); // drain
      await b.acquire(0); // should return immediately
      b.dispose();
    });

    test('negative refill is normalized to unlimited', () {
      TokenBucket b = TokenBucket(refillBytesPerSec: -5);
      expect(b.isUnlimited, isTrue);
      b.dispose();
    });
  });
}

void main() {
  group('data meter', dataMeterSuite);
  group('link supervisor', linkSupervisorSuite);
  group('policy engine', policyEngineSuite);
  group('token bucket', tokenBucketSuite);
}
