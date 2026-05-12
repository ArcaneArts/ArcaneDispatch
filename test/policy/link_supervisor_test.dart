import 'dart:async';

import 'package:arcane_dispatch/core/bonding_mode.dart';
import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/link_metric.dart';
import 'package:arcane_dispatch/core/policy.dart';
import 'package:arcane_dispatch/policy/link_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LinkSupervisor', () {
    test('emits a verdict for every link in the policy', () async {
      LinkSupervisor supervisor = LinkSupervisor();
      LinkHealthEvent? event;
      StreamSubscription<LinkHealthEvent> sub =
          supervisor.events.listen((LinkHealthEvent e) => event = e);

      supervisor.updatePolicy(_policy(<Link>[
        _link('p', LinkPriority.primary, source: '10.0.0.1'),
        _link('s', LinkPriority.secondary, source: '10.0.0.2'),
      ]));
      await _flush();

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
        LinkSupervisor supervisor = LinkSupervisor();
        List<LinkHealthEvent> events = <LinkHealthEvent>[];
        StreamSubscription<LinkHealthEvent> sub =
            supervisor.events.listen(events.add);

        supervisor.updatePolicy(_policy(
          <Link>[_link('p', LinkPriority.primary, source: '10.0.0.1')],
          killSwitch: true,
        ));
        await _flush();

        // No metric yet: the link is healthy by default (engine is permissive
        // when there's no signal). Sanity check the eligible path before we
        // poison it.
        expect(events.last.killSwitchActive, isFalse);

        supervisor.updateMetric(LinkMetric(
          linkId: 'p',
          capturedAt: DateTime.now().toUtc(),
          loss: 0.95, // way over the 0.30 threshold
        ));
        await _flush();

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
        LinkSupervisor supervisor = LinkSupervisor();
        LinkHealthEvent? event;
        StreamSubscription<LinkHealthEvent> sub =
            supervisor.events.listen((LinkHealthEvent e) => event = e);

        supervisor.updatePolicy(_policy(
          <Link>[_link('p', LinkPriority.primary, source: '10.0.0.1')],
          killSwitch: false,
        ));
        supervisor.updateMetric(LinkMetric(
          linkId: 'p',
          capturedAt: DateTime.now().toUtc(),
          loss: 0.95,
        ));
        await _flush();

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
      LinkSupervisor supervisor = LinkSupervisor();
      List<LinkHealthEvent> events = <LinkHealthEvent>[];
      StreamSubscription<LinkHealthEvent> sub =
          supervisor.events.listen(events.add);

      supervisor.updatePolicy(_policy(
        <Link>[_link('p', LinkPriority.primary, source: '10.0.0.1')],
        killSwitch: true,
      ));
      supervisor.updateMetric(LinkMetric(
        linkId: 'p',
        capturedAt: DateTime.now().toUtc(),
        loss: 0.95,
      ));
      await _flush();
      expect(events.last.killSwitchActive, isTrue);

      // Link recovers.
      supervisor.updateMetric(LinkMetric(
        linkId: 'p',
        capturedAt: DateTime.now().toUtc(),
        loss: 0.01,
        rttMs: 30.0,
      ));
      await _flush();

      expect(events.last.killSwitchActive, isFalse);
      expect(events.last.statuses['p'], LinkStatus.healthy);

      await sub.cancel();
      await supervisor.dispose();
    });

    test('updateMetrics replaces the full snapshot in one evaluation', () async {
      LinkSupervisor supervisor = LinkSupervisor();
      List<LinkHealthEvent> events = <LinkHealthEvent>[];
      StreamSubscription<LinkHealthEvent> sub =
          supervisor.events.listen(events.add);

      supervisor.updatePolicy(_policy(<Link>[
        _link('a', LinkPriority.primary, source: '10.0.0.1'),
        _link('b', LinkPriority.primary, source: '10.0.0.2'),
      ]));
      // First metric makes b unhealthy.
      supervisor.updateMetric(LinkMetric(
        linkId: 'b',
        capturedAt: DateTime.now().toUtc(),
        loss: 0.99,
      ));
      await _flush();
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
      await _flush();

      expect(events.length, afterFirst + 1);
      expect(events.last.statuses['a'], LinkStatus.healthy);
      expect(events.last.statuses['b'], LinkStatus.healthy);

      await sub.cancel();
      await supervisor.dispose();
    });

    test('evicts metrics for links that disappear from the policy', () async {
      LinkSupervisor supervisor = LinkSupervisor();
      LinkHealthEvent? event;
      StreamSubscription<LinkHealthEvent> sub =
          supervisor.events.listen((LinkHealthEvent e) => event = e);

      supervisor.updatePolicy(_policy(<Link>[
        _link('p', LinkPriority.primary, source: '10.0.0.1'),
        _link('q', LinkPriority.primary, source: '10.0.0.2'),
      ]));
      supervisor.updateMetric(LinkMetric(
        linkId: 'q',
        capturedAt: DateTime.now().toUtc(),
        rttMs: 25.0,
      ));
      await _flush();
      expect(event!.statuses.keys, contains('q'));

      // Drop q from the policy. The next evaluation should not mention it
      // even though we still know its metric (it should have been evicted).
      supervisor.updatePolicy(_policy(<Link>[
        _link('p', LinkPriority.primary, source: '10.0.0.1'),
      ]));
      await _flush();
      expect(event!.statuses.keys, isNot(contains('q')));
      expect(event!.statuses.keys, <String>{'p'});

      await sub.cancel();
      await supervisor.dispose();
    });

    test('ignores updates after dispose', () async {
      LinkSupervisor supervisor = LinkSupervisor();
      List<LinkHealthEvent> events = <LinkHealthEvent>[];
      StreamSubscription<LinkHealthEvent> sub =
          supervisor.events.listen(events.add);

      supervisor.updatePolicy(_policy(
        <Link>[_link('p', LinkPriority.primary, source: '10.0.0.1')],
      ));
      await _flush();
      int baseline = events.length;

      await supervisor.dispose();
      // Subscription closes when the controller closes; cancel in case to
      // avoid leaking the listener.
      await sub.cancel();

      // Updates after dispose must be no-ops.
      supervisor.updateMetric(LinkMetric(
        linkId: 'p',
        capturedAt: DateTime.now().toUtc(),
        loss: 0.99,
      ));
      supervisor.updatePolicy(_policy(<Link>[]));
      await _flush();
      expect(events.length, baseline);
    });

    test(
      'a link with priority Never is reported as disabled (not unhealthy)',
      () async {
        LinkSupervisor supervisor = LinkSupervisor();
        LinkHealthEvent? event;
        StreamSubscription<LinkHealthEvent> sub =
            supervisor.events.listen((LinkHealthEvent e) => event = e);

        supervisor.updatePolicy(_policy(<Link>[
          _link('a', LinkPriority.primary, source: '10.0.0.1'),
          _link('z', LinkPriority.never, source: '10.0.0.9'),
        ]));
        // Even with terrible metrics, a Never link must still report disabled.
        supervisor.updateMetric(LinkMetric(
          linkId: 'z',
          capturedAt: DateTime.now().toUtc(),
          loss: 0.99,
          rttMs: 5000.0,
        ));
        await _flush();

        expect(event!.statuses['z'], LinkStatus.disabled);
        expect(event!.statuses['a'], LinkStatus.healthy);

        await sub.cancel();
        await supervisor.dispose();
      },
    );

    test('linksWithStatus filters by status correctly', () async {
      LinkSupervisor supervisor = LinkSupervisor();
      LinkHealthEvent? event;
      StreamSubscription<LinkHealthEvent> sub =
          supervisor.events.listen((LinkHealthEvent e) => event = e);

      supervisor.updatePolicy(_policy(<Link>[
        _link('a', LinkPriority.primary, source: '10.0.0.1'),
        _link('b', LinkPriority.primary, source: '10.0.0.2'),
        _link('c', LinkPriority.secondary, source: '10.0.0.3'),
        _link('z', LinkPriority.never, source: '10.0.0.9'),
      ]));
      supervisor.updateMetric(LinkMetric(
        linkId: 'b',
        capturedAt: DateTime.now().toUtc(),
        loss: 0.95,
      ));
      await _flush();

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
        StreamSubscription<LinkHealthEvent> sub =
            supervisor.events.listen((LinkHealthEvent e) => event = e);

        supervisor.updatePolicy(_policy(<Link>[
          _link(
            'p',
            LinkPriority.primary,
            source: '10.0.0.1',
            dataCapBytes: 1_000_000_000,
          ),
          _link('q', LinkPriority.primary, source: '10.0.0.2'),
        ]));
        await _flush();

        expect(event!.statuses['p'], LinkStatus.unhealthy);
        expect(event!.statuses['q'], LinkStatus.healthy);

        await sub.cancel();
        await supervisor.dispose();
      },
    );

    test('lastEvent reflects most recent emit', () async {
      LinkSupervisor supervisor = LinkSupervisor();
      expect(supervisor.lastEvent, isNull);

      supervisor.updatePolicy(_policy(<Link>[
        _link('p', LinkPriority.primary, source: '10.0.0.1'),
      ]));
      await _flush();
      expect(supervisor.lastEvent, isNotNull);
      expect(supervisor.lastEvent!.statuses['p'], LinkStatus.healthy);

      await supervisor.dispose();
    });
  });
}

Policy _policy(List<Link> links, {bool killSwitch = false}) {
  return Policy(
    mode: BondingMode.speed,
    links: links,
    killSwitch: killSwitch,
  );
}

Link _link(
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
Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
}
