import 'dart:async';
import 'dart:io';

import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/link_metric.dart';
import 'package:arcane_dispatch/core/network_interface_repository.dart';
import 'package:arcane_dispatch/probes/link_probe.dart';
import 'package:arcane_dispatch/probes/link_probe_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a probe factory that returns probes which never start a timer of
/// their own. Tests drive the metric stream by calling [FakeProbe.emit].
class _ProbeRegistry {
  final List<FakeProbe> built = <FakeProbe>[];

  LinkProbeFactory factory() {
    return ({
      required Link link,
      required InternetAddress? Function() resolveSource,
      LinkProbeConfig config = const LinkProbeConfig(),
    }) {
      FakeProbe p = FakeProbe(link);
      built.add(p);
      return p;
    };
  }

  FakeProbe? byId(String id) {
    for (FakeProbe p in built) {
      if (p.link.id == id) {
        return p;
      }
    }
    return null;
  }
}

/// Stand-in probe that doesn't open any sockets or timers. Lets tests
/// validate the service's reconciliation logic in isolation.
class FakeProbe extends LinkProbe {
  bool started = false;
  bool timerCancelled = false;
  bool stopped = false;
  final StreamController<LinkMetric> _ctrl =
      StreamController<LinkMetric>.broadcast();

  FakeProbe(Link link)
      : super(
          link: link,
          resolveSource: () => InternetAddress.loopbackIPv4,
          attempt: ({
            required InternetAddress target,
            required int port,
            required InternetAddress? sourceAddress,
            required Duration timeout,
          }) async =>
              const ProbeOutcome.success(0.0),
        );

  @override
  Stream<LinkMetric> get stream => _ctrl.stream;

  @override
  LinkMetric? get latest => _latest;
  LinkMetric? _latest;

  @override
  void start() {
    started = true;
  }

  @override
  void cancelTimer() {
    timerCancelled = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    if (!_ctrl.isClosed) {
      await _ctrl.close();
    }
  }

  void emit(LinkMetric metric) {
    _latest = metric;
    _ctrl.add(metric);
  }
}

void main() {
  group('LinkProbeService', () {
    Link link(String id, {String? interfaceName, LinkPriority? priority}) {
      return Link(
        id: id,
        label: id,
        interfaceName: interfaceName ?? id,
        priority: priority ?? LinkPriority.primary,
      );
    }

    test('spawns one probe per probable link on updateLinks', () {
      _ProbeRegistry reg = _ProbeRegistry();
      LinkProbeService service = LinkProbeService(probeFactory: reg.factory());
      service.updateLinks(<Link>[link('a'), link('b')]);
      expect(reg.built.length, 2);
      expect(reg.built.every((FakeProbe p) => p.started), isTrue);
      service.cancelTimers();
    });

    test('skips probes for never-priority links', () {
      _ProbeRegistry reg = _ProbeRegistry();
      LinkProbeService service = LinkProbeService(probeFactory: reg.factory());
      service.updateLinks(<Link>[
        link('a'),
        link('b', priority: LinkPriority.never),
      ]);
      expect(reg.built.length, 1);
      expect(reg.built.single.link.id, 'a');
    });

    test('skips probes for links without interfaceName or sourceAddress', () {
      _ProbeRegistry reg = _ProbeRegistry();
      LinkProbeService service = LinkProbeService(probeFactory: reg.factory());
      service.updateLinks(<Link>[
        Link(id: 'a', label: 'a'), // no interface, no source
        link('b'),
      ]);
      expect(reg.built.length, 1);
      expect(reg.built.single.link.id, 'b');
    });

    test('removes probes whose link disappears', () async {
      _ProbeRegistry reg = _ProbeRegistry();
      LinkProbeService service = LinkProbeService(probeFactory: reg.factory());
      service.updateLinks(<Link>[link('a'), link('b')]);
      service.updateLinks(<Link>[link('a')]);
      // Wait one microtask cycle for the async dispose to schedule.
      await Future<void>.delayed(Duration.zero);
      FakeProbe? bProbe = reg.byId('b');
      expect(bProbe?.stopped, isTrue);
    });

    test('respawns probes when interfaceName or sourceAddress changes', () {
      _ProbeRegistry reg = _ProbeRegistry();
      LinkProbeService service = LinkProbeService(probeFactory: reg.factory());
      service.updateLinks(<Link>[link('a', interfaceName: 'en0')]);
      FakeProbe first = reg.byId('a')!;
      service.updateLinks(<Link>[link('a', interfaceName: 'en1')]);
      // Same id, new interface -> new probe instance
      expect(reg.built.length, 2);
      expect(first.timerCancelled, isTrue);
    });

    test('forwards probe metrics through the merged stream', () async {
      _ProbeRegistry reg = _ProbeRegistry();
      LinkProbeService service = LinkProbeService(probeFactory: reg.factory());
      service.updateLinks(<Link>[link('a')]);
      LinkMetric m = LinkMetric(
        linkId: 'a',
        capturedAt: DateTime.utc(2026, 5, 11),
        rttMs: 10,
      );
      List<LinkMetric> seen = <LinkMetric>[];
      StreamSubscription<LinkMetric> sub = service.metrics.listen(seen.add);
      reg.byId('a')!.emit(m);
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));
      expect(seen.single.linkId, 'a');
      expect(seen.single.rttMs, 10);
      await sub.cancel();
    });

    test('snapshot returns the per-link latest', () {
      _ProbeRegistry reg = _ProbeRegistry();
      LinkProbeService service = LinkProbeService(probeFactory: reg.factory());
      service.updateLinks(<Link>[link('a'), link('b')]);
      reg.byId('a')!.emit(LinkMetric(linkId: 'a', capturedAt: DateTime.utc(2026), rttMs: 1));
      reg.byId('b')!.emit(LinkMetric(linkId: 'b', capturedAt: DateTime.utc(2026), rttMs: 2));
      Map<String, LinkMetric> snap = service.snapshot();
      expect(snap['a']!.rttMs, 1);
      expect(snap['b']!.rttMs, 2);
    });

    test('resolveLinkSource picks an IPv4 from the matching interface', () {
      List<NetworkInterfaceSnapshot> interfaces = <NetworkInterfaceSnapshot>[
        NetworkInterfaceSnapshot(
          name: 'en0',
          index: 1,
          addresses: <InternetAddress>[
            InternetAddress('10.0.0.4'),
            InternetAddress('fe80::1'),
          ],
        ),
      ];
      InternetAddress? addr = resolveLinkSource(
        Link(id: 'l', label: 'l', interfaceName: 'en0'),
        interfaces,
      );
      expect(addr?.address, '10.0.0.4');
    });

    test('resolveLinkSource prefers explicit sourceAddress over interface',
        () {
      List<NetworkInterfaceSnapshot> interfaces = <NetworkInterfaceSnapshot>[
        NetworkInterfaceSnapshot(
          name: 'en0',
          index: 1,
          addresses: <InternetAddress>[InternetAddress('10.0.0.4')],
        ),
      ];
      InternetAddress? addr = resolveLinkSource(
        Link(
          id: 'l',
          label: 'l',
          interfaceName: 'en0',
          sourceAddress: '192.168.5.5',
        ),
        interfaces,
      );
      expect(addr?.address, '192.168.5.5');
    });

    test('resolveLinkSource returns null when neither source matches', () {
      InternetAddress? addr = resolveLinkSource(
        Link(id: 'l', label: 'l'),
        <NetworkInterfaceSnapshot>[],
      );
      expect(addr, isNull);
    });

    test('stop tears down all probes', () async {
      _ProbeRegistry reg = _ProbeRegistry();
      LinkProbeService service = LinkProbeService(probeFactory: reg.factory());
      service.updateLinks(<Link>[link('a'), link('b')]);
      await service.stop();
      expect(reg.built.every((FakeProbe p) => p.stopped), isTrue);
    });
  });
}
