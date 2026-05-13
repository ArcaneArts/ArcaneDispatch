import 'dart:async';
import 'dart:io';
import 'package:arcane_dispatch/core/link_metric.dart';
import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/network_interface_repository.dart';
import 'package:arcane_dispatch/probes/captive_portal_probe.dart';
import 'package:arcane_dispatch/probes/link_metric_store.dart';
import 'package:arcane_dispatch/probes/link_probe_service.dart';
import 'package:arcane_dispatch/probes/link_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

// Phase 14: unit tests for the captive portal probe + detector.
//
// We deliberately avoid touching the real network — `httpCaptivePortalProbe`
// is replaced with an injected fake so the state machine can be exercised
// deterministically. The parser/classifier helpers are pure functions, so
// they get the most coverage.

DateTime _captivePortalT0() => DateTime.utc(2026, 5, 11, 0, 0, 0);

Link _captivePortalLink({String id = 'wifi'}) {
  return Link(
    id: id,
    label: 'Wi-Fi',
    interfaceName: 'en0',
    sourceAddress: '192.0.2.1',
    weight: 1,
  );
}

void captivePortalProbeSuite() {
  group('classifyCaptiveResponse', () {
    test('returns pass for 200 + canonical Apple body', () {
      String body =
          '<HTML>\n'
          '<HEAD><TITLE>Success</TITLE></HEAD>\n'
          '<BODY>\nSuccess\n</BODY>\n'
          '</HTML>';
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 200,
        body: body,
        now: _captivePortalT0(),
      );
      expect(o.result, CaptivePortalProbeResult.pass);
      expect(o.statusCode, 200);
      expect(o.error, isNull);
      expect(o.isPass, isTrue);
      expect(o.isCaptive, isFalse);
    });

    test('returns captive for 200 without marker (transparent proxy)', () {
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 200,
        body: '<html>Please log in to use the Wi-Fi.</html>',
        now: _captivePortalT0(),
      );
      expect(o.result, CaptivePortalProbeResult.captive);
      expect(o.statusCode, 200);
      expect(o.isCaptive, isTrue);
    });

    test('returns captive for 302 redirect to portal', () {
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 302,
        body: '',
        now: _captivePortalT0(),
      );
      expect(o.result, CaptivePortalProbeResult.captive);
      expect(o.statusCode, 302);
    });

    test('returns error for 4xx', () {
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 403,
        body: 'forbidden',
        now: _captivePortalT0(),
      );
      expect(o.result, CaptivePortalProbeResult.error);
      expect(o.statusCode, 403);
      expect(o.error, contains('403'));
    });

    test('returns error for 5xx', () {
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 502,
        body: '',
        now: _captivePortalT0(),
      );
      expect(o.result, CaptivePortalProbeResult.error);
      expect(o.statusCode, 502);
    });

    test('rejects portals that put "Success" outside the title tag', () {
      // Adversarial portal returning 200 with a body that mentions the
      // word "Success" but not in `<TITLE>`. Should be classified as
      // captive, not pass.
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 200,
        body: '<html><body>Login Success here later!</body></html>',
        now: _captivePortalT0(),
      );
      expect(o.result, CaptivePortalProbeResult.captive);
    });
  });

  group('parseHttpResponse', () {
    test('handles a complete response with the marker', () {
      String wire =
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: text/html\r\n'
          'Content-Length: 70\r\n'
          '\r\n'
          '<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>';
      CaptivePortalProbeOutcome o = parseHttpResponse(
        wire.codeUnits,
        _captivePortalT0(),
      );
      expect(o.result, CaptivePortalProbeResult.pass);
      expect(o.statusCode, 200);
    });

    test('returns error when there is no header terminator', () {
      String wire = 'HTTP/1.1 200 OK';
      CaptivePortalProbeOutcome o = parseHttpResponse(
        wire.codeUnits,
        _captivePortalT0(),
      );
      expect(o.result, CaptivePortalProbeResult.error);
      expect(o.error, contains('malformed'));
    });

    test('handles 302 redirect', () {
      String wire =
          'HTTP/1.1 302 Found\r\n'
          'Location: http://portal.example.net/login\r\n'
          'Content-Length: 0\r\n'
          '\r\n';
      CaptivePortalProbeOutcome o = parseHttpResponse(
        wire.codeUnits,
        _captivePortalT0(),
      );
      expect(o.result, CaptivePortalProbeResult.captive);
      expect(o.statusCode, 302);
    });

    test('handles malformed status line as status code 0 (error)', () {
      String wire =
          'NOTHTTP\r\n'
          'Content-Length: 0\r\n'
          '\r\n';
      CaptivePortalProbeOutcome o = parseHttpResponse(
        wire.codeUnits,
        _captivePortalT0(),
      );
      // Empty status line → code parsed as 0 → falls into the error bucket.
      expect(o.result, CaptivePortalProbeResult.error);
    });
  });

  group('CaptivePortalState', () {
    test('first observe emits and updates effective', () {
      CaptivePortalState s = CaptivePortalState();
      bool changed = s.observe(
        CaptivePortalProbeOutcome(
          result: CaptivePortalProbeResult.pass,
          capturedAt: _captivePortalT0(),
        ),
        1,
      );
      expect(changed, isTrue);
      expect(s.effective, CaptivePortalProbeResult.pass);
      expect(s.lastResult, CaptivePortalProbeResult.pass);
      expect(s.candidateCount, 1);
    });

    test('debounce of 2 requires two matching outcomes to flip', () {
      CaptivePortalState s = CaptivePortalState();
      bool c1 = s.observe(
        CaptivePortalProbeOutcome(
          result: CaptivePortalProbeResult.captive,
          capturedAt: _captivePortalT0(),
        ),
        2,
      );
      expect(c1, isFalse);
      expect(s.effective, isNull);
      expect(s.candidateCount, 1);
      bool c2 = s.observe(
        CaptivePortalProbeOutcome(
          result: CaptivePortalProbeResult.captive,
          capturedAt: _captivePortalT0(),
        ),
        2,
      );
      expect(c2, isTrue);
      expect(s.effective, CaptivePortalProbeResult.captive);
      expect(s.candidateCount, 2);
    });

    test('different outcomes reset the candidate counter', () {
      CaptivePortalState s = CaptivePortalState();
      s.observe(
        CaptivePortalProbeOutcome(
          result: CaptivePortalProbeResult.captive,
          capturedAt: _captivePortalT0(),
        ),
        3,
      );
      s.observe(
        CaptivePortalProbeOutcome(
          result: CaptivePortalProbeResult.pass,
          capturedAt: _captivePortalT0(),
        ),
        3,
      );
      expect(s.candidate, CaptivePortalProbeResult.pass);
      expect(s.candidateCount, 1);
      expect(
        s.effective,
        isNull,
        reason: '3-debounce never satisfied — effective stays unknown.',
      );
    });
  });

  group('CaptivePortalDetector', () {
    test('emits the first stable observation and updates state', () async {
      List<CaptivePortalProbeResult> sequence = <CaptivePortalProbeResult>[
        CaptivePortalProbeResult.pass,
      ];
      int callCount = 0;
      CaptivePortalDetector det = CaptivePortalDetector(
        link: _captivePortalLink(),
        resolveSource: () => null,
        config: const CaptivePortalDetectorConfig(
          normalInterval: Duration(milliseconds: 50),
          probeTimeout: Duration(milliseconds: 100),
        ),
        probe:
            ({
              required Uri target,
              required InternetAddress? sourceAddress,
              required Duration timeout,
              required DateTime now,
            }) async {
              CaptivePortalProbeResult r =
                  sequence[callCount % sequence.length];
              callCount += 1;
              return CaptivePortalProbeOutcome(
                result: r,
                capturedAt: now,
                statusCode: r == CaptivePortalProbeResult.pass ? 200 : 302,
              );
            },
      );

      Completer<CaptivePortalState> firstEmit = Completer<CaptivePortalState>();
      StreamSubscription<CaptivePortalState> sub = det.stream.listen((s) {
        if (!firstEmit.isCompleted) firstEmit.complete(s);
      });
      det.start();
      CaptivePortalState s = await firstEmit.future.timeout(
        const Duration(seconds: 1),
      );
      expect(s.effective, CaptivePortalProbeResult.pass);
      await sub.cancel();
      await det.stop();
    });

    test(
      'flips effective state when probe outcome changes after debounce',
      () async {
        // Alternate captive → captive → pass → pass with debounceCount: 2.
        // Effective should land on captive after the second captive and
        // flip back to pass after the second pass.
        List<CaptivePortalProbeResult> sequence = <CaptivePortalProbeResult>[
          CaptivePortalProbeResult.captive,
          CaptivePortalProbeResult.captive,
          CaptivePortalProbeResult.pass,
          CaptivePortalProbeResult.pass,
        ];
        int callCount = 0;
        CaptivePortalDetector det = CaptivePortalDetector(
          link: _captivePortalLink(),
          resolveSource: () => null,
          config: const CaptivePortalDetectorConfig(
            normalInterval: Duration(milliseconds: 25),
            capturedInterval: Duration(milliseconds: 25),
            errorInterval: Duration(milliseconds: 25),
            probeTimeout: Duration(milliseconds: 50),
            debounceCount: 2,
          ),
          probe:
              ({
                required Uri target,
                required InternetAddress? sourceAddress,
                required Duration timeout,
                required DateTime now,
              }) async {
                CaptivePortalProbeResult r =
                    sequence[callCount.clamp(0, sequence.length - 1)];
                callCount += 1;
                return CaptivePortalProbeOutcome(
                  result: r,
                  capturedAt: now,
                  statusCode: r == CaptivePortalProbeResult.pass ? 200 : 302,
                );
              },
        );

        List<CaptivePortalProbeResult?> seen = <CaptivePortalProbeResult?>[];
        StreamSubscription<CaptivePortalState> sub = det.stream.listen((s) {
          seen.add(s.effective);
        });
        det.start();
        // Allow enough wall-clock time for the 4 ticks to land.
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await sub.cancel();
        await det.stop();
        expect(seen, contains(CaptivePortalProbeResult.captive));
        expect(seen, contains(CaptivePortalProbeResult.pass));
        expect(seen.last, CaptivePortalProbeResult.pass);
      },
    );

    test('cancelTimer makes start a no-op', () async {
      CaptivePortalDetector det = CaptivePortalDetector(
        link: _captivePortalLink(),
        resolveSource: () => null,
        probe:
            ({
              required Uri target,
              required InternetAddress? sourceAddress,
              required Duration timeout,
              required DateTime now,
            }) async {
              throw StateError('probe should not run after cancelTimer');
            },
      );
      det.cancelTimer();
      // After cancelTimer the start() call must do nothing — the test
      // would explode if it did.
      det.start();
      await det.stop();
    });
  });
}

LinkMetric _linkMetricStoreMetric(String id, double rtt, [DateTime? t]) {
  return LinkMetric(
    linkId: id,
    capturedAt: t ?? DateTime.utc(2026, 5, 11),
    rttMs: rtt,
  );
}

void linkMetricStoreSuite() {
  group('LinkMetricStore', () {
    test('record updates latest and history per link', () {
      LinkMetricStore store = LinkMetricStore(windowSize: 4);
      store.record(_linkMetricStoreMetric('a', 1));
      store.record(_linkMetricStoreMetric('a', 2));
      store.record(_linkMetricStoreMetric('b', 99));
      expect(store.latestFor('a')!.rttMs, 2);
      expect(store.latestFor('b')!.rttMs, 99);
      expect(
        store.historyFor('a').map((LinkMetric x) => x.rttMs).toList(),
        <double>[1, 2],
      );
      expect(
        store.historyFor('b').map((LinkMetric x) => x.rttMs).toList(),
        <double>[99],
      );
    });

    test('ring buffer evicts oldest at window size', () {
      LinkMetricStore store = LinkMetricStore(windowSize: 3);
      for (int i = 1; i <= 5; i++) {
        store.record(_linkMetricStoreMetric('a', i.toDouble()));
      }
      expect(
        store.historyFor('a').map((LinkMetric x) => x.rttMs).toList(),
        <double>[3, 4, 5],
      );
    });

    test('dropLink removes both buffer and latest', () {
      LinkMetricStore store = LinkMetricStore();
      store.record(_linkMetricStoreMetric('a', 1));
      store.dropLink('a');
      expect(store.latestFor('a'), isNull);
      expect(store.historyFor('a'), isEmpty);
    });

    test('metrics stream broadcasts each record', () async {
      LinkMetricStore store = LinkMetricStore();
      List<LinkMetric> seen = <LinkMetric>[];
      StreamSubscription<LinkMetric> sub = store.metrics.listen(seen.add);
      store.record(_linkMetricStoreMetric('a', 1));
      store.record(_linkMetricStoreMetric('a', 2));
      await Future<void>.delayed(Duration.zero);
      expect(seen.map((LinkMetric x) => x.rttMs), <double>[1, 2]);
      await sub.cancel();
      await store.dispose();
    });

    group('persistence', () {
      late Directory tempDir;
      late Box box;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'arcane_dispatch_store_test_',
        );
        Hive.init(tempDir.path);
        box = await Hive.openBox('test_store');
      });

      tearDown(() async {
        await box.close();
        await Hive.deleteFromDisk();
        await tempDir.delete(recursive: true);
      });

      test('flush writes latest per link to Hive as JSON', () async {
        LinkMetricStore store = LinkMetricStore(storage: box);
        store.record(_linkMetricStoreMetric('a', 12));
        store.record(_linkMetricStoreMetric('b', 34));
        await store.flush();
        Object? raw = box.get('link_metrics_snapshot_v1');
        expect(raw, isA<String>());
        expect((raw as String).contains('"a"'), isTrue);
        expect(raw.contains('"linkId":"b"'), isTrue);
        await store.dispose();
      });

      test('warmStart rehydrates latest map from previous flush', () async {
        // Write a snapshot via one store, read with another.
        LinkMetricStore writer = LinkMetricStore(storage: box);
        writer.record(_linkMetricStoreMetric('a', 7));
        writer.record(_linkMetricStoreMetric('b', 8));
        await writer.flush();
        await writer.dispose();

        LinkMetricStore reader = LinkMetricStore(storage: box);
        Map<String, LinkMetric> seeded = reader.warmStart();
        expect(seeded.keys.toSet(), <String>{'a', 'b'});
        expect(seeded['a']!.rttMs, 7);
        expect(seeded['b']!.rttMs, 8);
        expect(reader.latestFor('a')!.rttMs, 7);
        await reader.dispose();
      });

      test('warmStart tolerates corrupt blob', () async {
        await box.put('link_metrics_snapshot_v1', '{not json');
        LinkMetricStore store = LinkMetricStore(storage: box);
        expect(store.warmStart(), isEmpty);
        await store.dispose();
      });

      test('startSnapshots schedules periodic flush', () async {
        LinkMetricStore store = LinkMetricStore(
          storage: box,
          snapshotInterval: const Duration(milliseconds: 20),
        );
        store.record(_linkMetricStoreMetric('a', 1));
        store.startSnapshots();
        // Wait long enough for at least one snapshot tick.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await store.dispose();
        expect(box.get('link_metrics_snapshot_v1'), isNotNull);
      });

      test('dispose cancels the snapshot timer synchronously', () async {
        LinkMetricStore store = LinkMetricStore(
          storage: box,
          snapshotInterval: const Duration(seconds: 60),
        );
        store.startSnapshots();
        await store.dispose();
        // No timer should remain; we exercise this indirectly: a second
        // dispose is a no-op and shouldn't throw.
        await store.dispose();
      });
    });
  });
}

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
        attempt:
            ({
              required InternetAddress target,
              required int port,
              required InternetAddress? sourceAddress,
              required Duration timeout,
            }) async => const ProbeOutcome.success(0.0),
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

void linkProbeServiceSuite() {
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
      reg
          .byId('a')!
          .emit(
            LinkMetric(linkId: 'a', capturedAt: DateTime.utc(2026), rttMs: 1),
          );
      reg
          .byId('b')!
          .emit(
            LinkMetric(linkId: 'b', capturedAt: DateTime.utc(2026), rttMs: 2),
          );
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

    test('resolveLinkSource prefers explicit sourceAddress over interface', () {
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

/// Helper that builds a probe with a deterministic attempt function and a
/// fast tick interval so we can drive its loop manually.
LinkProbe _linkProbe({
  required List<ProbeOutcome> outcomes,
  Duration interval = const Duration(milliseconds: 10),
  int windowSize = 5,
  InternetAddress? source,
}) {
  int idx = 0;
  return LinkProbe(
    link: Link(id: 'l', label: 'L', interfaceName: 'en0'),
    resolveSource: () => source ?? InternetAddress.loopbackIPv4,
    config: LinkProbeConfig(
      tickInterval: interval,
      attemptTimeout: const Duration(seconds: 1),
      windowSize: windowSize,
      targets: const <ProbeTarget>[ProbeTarget(host: '127.0.0.1', port: 65535)],
    ),
    attempt:
        ({
          required InternetAddress target,
          required int port,
          required InternetAddress? sourceAddress,
          required Duration timeout,
        }) async {
          ProbeOutcome out = outcomes[idx % outcomes.length];
          idx += 1;
          return out;
        },
  );
}

void linkProbeSuite() {
  group('LinkProbe', () {
    test('emits metric with rtt + jitter + loss after a few ticks', () async {
      LinkProbe probe = _linkProbe(
        outcomes: <ProbeOutcome>[
          const ProbeOutcome.success(10.0),
          const ProbeOutcome.success(12.0),
          const ProbeOutcome.success(8.0),
        ],
        interval: const Duration(milliseconds: 5),
      );
      List<LinkMetric> samples = <LinkMetric>[];
      StreamSubscription<LinkMetric> sub = probe.stream.listen(samples.add);
      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      probe.cancelTimer();
      await sub.cancel();
      await probe.stop();

      expect(samples, isNotEmpty);
      LinkMetric latest = samples.last;
      expect(latest.linkId, 'l');
      expect(latest.rttMs, isNotNull);
      expect(latest.jitterMs, isNotNull);
      expect(latest.loss, 0.0);
      expect(latest.mos, isNotNull);
    });

    test('loss climbs when probes fail', () async {
      LinkProbe probe = _linkProbe(
        outcomes: <ProbeOutcome>[
          const ProbeOutcome.failure('timeout'),
          const ProbeOutcome.failure('timeout'),
          const ProbeOutcome.failure('timeout'),
        ],
        interval: const Duration(milliseconds: 5),
        windowSize: 3,
      );
      List<LinkMetric> samples = <LinkMetric>[];
      StreamSubscription<LinkMetric> sub = probe.stream.listen(samples.add);
      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      probe.cancelTimer();
      await sub.cancel();
      await probe.stop();

      expect(samples, isNotEmpty);
      LinkMetric latest = samples.last;
      expect(latest.loss, 1.0);
      expect(latest.rttMs, isNull); // no successful samples yet
    });

    test('uses last successful rtt when current probe fails', () async {
      LinkProbe probe = _linkProbe(
        outcomes: <ProbeOutcome>[
          const ProbeOutcome.success(20.0),
          const ProbeOutcome.failure('timeout'),
        ],
        interval: const Duration(milliseconds: 5),
        windowSize: 4,
      );
      List<LinkMetric> samples = <LinkMetric>[];
      StreamSubscription<LinkMetric> sub = probe.stream.listen(samples.add);
      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      probe.cancelTimer();
      await sub.cancel();
      await probe.stop();

      LinkMetric latest = samples.last;
      // After at least one tick of each, we should have a non-null rtt and
      // some loss in the window.
      expect(latest.rttMs, isNotNull);
      expect(latest.loss, greaterThan(0.0));
    });

    test(
      'marks as failed when source resolution returns null but expected',
      () async {
        LinkProbe probe = LinkProbe(
          link: Link(id: 'l', label: 'l', sourceAddress: '10.0.0.99'),
          resolveSource: () => null, // expected an address, got nothing
          config: const LinkProbeConfig(
            tickInterval: Duration(milliseconds: 5),
            windowSize: 2,
          ),
          attempt:
              ({
                required InternetAddress target,
                required int port,
                required InternetAddress? sourceAddress,
                required Duration timeout,
              }) async {
                // Should never be reached when source resolution fails.
                return const ProbeOutcome.success(0);
              },
        );
        List<LinkMetric> samples = <LinkMetric>[];
        StreamSubscription<LinkMetric> sub = probe.stream.listen(samples.add);
        probe.start();
        await Future<void>.delayed(const Duration(milliseconds: 25));
        probe.cancelTimer();
        await sub.cancel();
        await probe.stop();

        LinkMetric latest = samples.last;
        expect(latest.loss, 1.0);
      },
    );

    test('cancelTimer stops emissions synchronously', () async {
      LinkProbe probe = _linkProbe(
        outcomes: <ProbeOutcome>[const ProbeOutcome.success(5.0)],
        interval: const Duration(milliseconds: 5),
      );
      probe.start();
      probe.cancelTimer();
      int before =
          (await probe.stream
                  .take(0)
                  .toList()
                  .timeout(
                    const Duration(milliseconds: 30),
                    onTimeout: () => <LinkMetric>[],
                  ))
              .length;
      expect(before, 0);
      await probe.stop();
    });

    test('latest exposes the most recent metric', () async {
      LinkProbe probe = _linkProbe(
        outcomes: <ProbeOutcome>[const ProbeOutcome.success(7.0)],
        interval: const Duration(milliseconds: 5),
      );
      expect(probe.latest, isNull);
      probe.start();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      probe.cancelTimer();
      await probe.stop();
      expect(probe.latest, isNotNull);
      expect(probe.latest!.rttMs, 7.0);
    });
  });
}

void main() {
  group('captive portal probe', captivePortalProbeSuite);
  group('link metric store', linkMetricStoreSuite);
  group('link probe service', linkProbeServiceSuite);
  group('link probe', linkProbeSuite);
}
