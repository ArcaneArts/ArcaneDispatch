import 'dart:async';
import 'dart:io';

import 'package:arcane_dispatch/bridge/tunnel_channel.dart';
import 'package:arcane_dispatch/core/bonding_mode.dart';
import 'package:arcane_dispatch/core/dispatch_settings.dart';
import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/network_interface_repository.dart';
import 'package:arcane_dispatch/core/policy.dart';
import 'package:arcane_dispatch/core/socks_proxy_server.dart';
import 'package:arcane_dispatch/core/weighted_address.dart';
import 'package:arcane_dispatch/platform/network_naming_service.dart';
import 'package:arcane_dispatch/policy/byte_accountant.dart';
import 'package:arcane_dispatch/probes/link_metric_store.dart';
import 'package:arcane_dispatch/probes/link_probe_service.dart';
import 'package:arcane_dispatch/protocol/protocol_ladder.dart';
import 'package:arcane_dispatch/screen/dispatch_controller.dart';
import 'package:arcane_dispatch/screen/home_screen.dart';
import 'package:arcane_dispatch/transport/socks_transport.dart';
import 'package:arcane_dispatch/transport/transport.dart';
import 'package:arcane_dispatch/ui/dispatch_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';

// Tests for `TunnelChannel.setServer` / `TunnelChannel.getServer`.
//
// Drives the real `MethodChannel` (no fake), but installs a custom
// platform handler so the test runs cross-platform. This is the layer we
// can't cover from `test/transport/tunnel_transport_test.dart` because
// that file substitutes the entire channel; here we exercise the actual
// dispatch into [MethodChannel.invokeMethod].

void bridgeSuite() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannel channel;
  late TunnelChannel client;

  setUp(() {
    channel = const MethodChannel(TunnelChannel.channelName);
    client = TunnelChannel(channel: channel);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'setServer encodes endpoint + token and round-trips a bool reply',
    () async {
      String? capturedEndpoint;
      String? capturedToken;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            expect(call.method, 'setServer');
            Map<Object?, Object?> args =
                call.arguments as Map<Object?, Object?>;
            capturedEndpoint = args['endpoint'] as String?;
            capturedToken = args['token'] as String?;
            return true;
          });

      bool ok = await client.setServer(
        endpoint: 'relay.example.com:4430',
        token: 'opaque-bearer',
      );

      expect(ok, isTrue);
      expect(capturedEndpoint, 'relay.example.com:4430');
      expect(capturedToken, 'opaque-bearer');
    },
  );

  test('setServer returns false when the platform replies non-true', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    bool ok = await client.setServer(endpoint: 'host:1', token: 't');
    expect(ok, isFalse);
  });

  test(
    'setServer surfaces TunnelUnavailableException when no plugin',
    () async {
      // No handler installed => MissingPluginException.
      expect(
        () => client.setServer(endpoint: 'h', token: 't'),
        throwsA(isA<TunnelUnavailableException>()),
      );
    },
  );

  test('getServer parses the platform map into a typed config', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'getServer');
          return <String, Object?>{
            'endpoint': 'relay.example.com:4430',
            'tokenSet': true,
          };
        });
    TunnelServerConfig cfg = await client.getServer();
    expect(cfg.endpoint, 'relay.example.com:4430');
    expect(cfg.tokenSet, isTrue);
    expect(cfg.isConfigured, isTrue);
  });

  test('getServer treats a non-map reply as empty', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    TunnelServerConfig cfg = await client.getServer();
    expect(cfg.endpoint, isEmpty);
    expect(cfg.tokenSet, isFalse);
    expect(cfg.isConfigured, isFalse);
  });

  test('TunnelServerConfig.empty is unconfigured', () {
    TunnelServerConfig cfg = TunnelServerConfig.empty();
    expect(cfg.endpoint, isEmpty);
    expect(cfg.tokenSet, isFalse);
    expect(cfg.isConfigured, isFalse);
  });

  test('TunnelServerConfig.fromPlatform tolerates missing keys', () {
    TunnelServerConfig cfg = TunnelServerConfig.fromPlatform(
      <Object?, Object?>{},
    );
    expect(cfg.endpoint, isEmpty);
    expect(cfg.tokenSet, isFalse);
  });

  test('getClientPublicKey round-trips the platform base64 reply', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'getClientPublicKey');
          // 32 zero bytes encoded as base64.
          return 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
        });
    String? pub = await client.getClientPublicKey();
    expect(pub, 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
  });

  test(
    'getClientPublicKey returns null when the platform returns null',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => null);
      String? pub = await client.getClientPublicKey();
      expect(pub, isNull);
    },
  );

  test('setResponderPublicKey forwards the base64 arg', () async {
    String? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          expect(call.method, 'setResponderPublicKey');
          Map<Object?, Object?> args = call.arguments as Map<Object?, Object?>;
          captured = args['publicKey'] as String?;
          return true;
        });
    bool ok = await client.setResponderPublicKey('AAAA');
    expect(ok, isTrue);
    expect(captured, 'AAAA');
  });

  test('setResponderPublicKey reports false on non-true reply', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => 0);
    bool ok = await client.setResponderPublicKey('AAAA');
    expect(ok, isFalse);
  });
}

// Protocol-ladder tests. Lock the fallback ordering, the
// timeout behavior, and the diagnostic surface that the UI / metric
// stream consumes via [LadderResult.toDecision].

/// Test transport that records what was sent and never blocks. The
/// ladder itself doesn't care about send semantics — only `negotiate`
/// is exercised — but this lets us assert that [LadderResult.chosen]
/// carries a *working* transport rather than null on success.
class _FakeTransport implements LinkProtocolTransport {
  @override
  final LinkProtocol protocol;
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  bool _closed = false;
  List<Uint8List> sent = <Uint8List>[];

  _FakeTransport(this.protocol);

  @override
  bool get isClosed => _closed;

  @override
  bool send(Uint8List bytes) {
    if (_closed) return false;
    sent.add(bytes);
    return true;
  }

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _inbound.close();
  }
}

void protocolSuite() {
  group('LinkProtocolCodec', () {
    test('round-trips every variant via wireName <-> parse', () {
      for (LinkProtocol p in LinkProtocol.values) {
        expect(LinkProtocolCodec.parse(p.wireName), p);
      }
    });

    test('unknown string falls back to UDP', () {
      expect(LinkProtocolCodec.parse('flooper'), LinkProtocol.udp443);
    });
  });

  group('ProtocolLadder.negotiate', () {
    test('returns the first rung on the happy path', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) =>
            () async => ProbeResult(
              protocol: p,
              transport: _FakeTransport(p),
              elapsed: const Duration(milliseconds: 10),
            ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.chosen?.protocol, LinkProtocol.udp443);
      expect(
        result.attempts,
        hasLength(1),
        reason: 'No fallback rungs should be attempted on first success',
      );
      expect(result.toDecision().rejected, isEmpty);
    });

    test('falls back to TCP when UDP fails', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) => () async {
          if (p == LinkProtocol.udp443) {
            return ProbeResult.failed(
              protocol: p,
              reason: 'connection refused',
              elapsed: const Duration(milliseconds: 5),
            );
          }
          return ProbeResult(
            protocol: p,
            transport: _FakeTransport(p),
            elapsed: const Duration(milliseconds: 20),
          );
        },
      );

      expect(result.isSuccess, isTrue);
      expect(result.chosen?.protocol, LinkProtocol.tcp443);
      expect(result.attempts.map((ProbeResult r) => r.protocol), <LinkProtocol>[
        LinkProtocol.udp443,
        LinkProtocol.tcp443,
      ]);
      expect(result.toDecision().rejected, <LinkProtocol>[LinkProtocol.udp443]);
    });

    test('falls all the way through UDP → TCP → TLS', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) => () async {
          if (p != LinkProtocol.tls443) {
            return ProbeResult.failed(
              protocol: p,
              reason: 'middle-box blocked',
              elapsed: const Duration(milliseconds: 5),
            );
          }
          return ProbeResult(
            protocol: p,
            transport: _FakeTransport(p),
            elapsed: const Duration(milliseconds: 40),
          );
        },
      );

      expect(result.isSuccess, isTrue);
      expect(result.chosen?.protocol, LinkProtocol.tls443);
      expect(result.toDecision().rejected, <LinkProtocol>[
        LinkProtocol.udp443,
        LinkProtocol.tcp443,
      ]);
    });

    test('returns failure when every rung fails', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) =>
            () async => ProbeResult.failed(
              protocol: p,
              reason: 'no route',
              elapsed: const Duration(milliseconds: 5),
            ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.chosen, isNull);
      expect(result.attempts, hasLength(3));
      expect(result.attempts.every((ProbeResult r) => !r.isSuccess), isTrue);
    });

    test('respects perStepTimeout when a probe never returns', () async {
      // Make every step hang. Timeout MUST kick in on each rung; total
      // elapsed should be roughly N * perStepTimeout.
      ProtocolLadder ladder = const ProtocolLadder(
        perStepTimeout: Duration(milliseconds: 30),
      );

      Future<ProbeResult> hang(LinkProtocol p) {
        Completer<ProbeResult> c = Completer<ProbeResult>();
        // Never completes.
        return c.future;
      }

      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) =>
            () => hang(p),
      );

      expect(result.isSuccess, isFalse);
      expect(result.attempts, hasLength(3));
      expect(
        result.attempts.every(
          (ProbeResult r) => r.failureReason!.contains('timed out'),
        ),
        isTrue,
      );
      // Should be roughly 3 * 30 ms; allow generous slack for CI.
      expect(result.totalElapsed.inMilliseconds, greaterThanOrEqualTo(85));
      expect(result.totalElapsed.inMilliseconds, lessThanOrEqualTo(800));
    });

    test('respects a custom ordering', () async {
      ProtocolLadder ladder = const ProtocolLadder(
        ordering: <LinkProtocol>[LinkProtocol.tls443, LinkProtocol.udp443],
      );

      List<LinkProtocol> attempted = <LinkProtocol>[];
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) => () async {
          attempted.add(p);
          if (p == LinkProtocol.tls443) {
            return ProbeResult.failed(
              protocol: p,
              reason: 'dpi blocked',
              elapsed: const Duration(milliseconds: 5),
            );
          }
          return ProbeResult(
            protocol: p,
            transport: _FakeTransport(p),
            elapsed: const Duration(milliseconds: 10),
          );
        },
      );

      expect(attempted, <LinkProtocol>[
        LinkProtocol.tls443,
        LinkProtocol.udp443,
      ]);
      expect(result.chosen?.protocol, LinkProtocol.udp443);
    });

    test('converts a thrown error into a failure result', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) => () async {
          if (p == LinkProtocol.udp443) {
            throw const FormatException('handshake garbled');
          }
          return ProbeResult(
            protocol: p,
            transport: _FakeTransport(p),
            elapsed: const Duration(milliseconds: 10),
          );
        },
      );

      expect(result.attempts.first.isSuccess, isFalse);
      expect(
        result.attempts.first.failureReason,
        contains('handshake garbled'),
      );
      expect(result.chosen?.protocol, LinkProtocol.tcp443);
    });
  });

  group('ProtocolLadder.tryStep', () {
    test('returns the probe outcome verbatim on success', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      ProbeResult r = await ladder.tryStep(
        LinkProtocol.udp443,
        () async => ProbeResult(
          protocol: LinkProtocol.udp443,
          transport: _FakeTransport(LinkProtocol.udp443),
          elapsed: const Duration(milliseconds: 1),
        ),
      );
      expect(r.isSuccess, isTrue);
      expect(r.protocol, LinkProtocol.udp443);
    });

    test('respects perStepTimeout for a single-step run', () async {
      ProtocolLadder ladder = const ProtocolLadder(
        perStepTimeout: Duration(milliseconds: 25),
      );
      ProbeResult r = await ladder.tryStep(
        LinkProtocol.udp443,
        () => Completer<ProbeResult>().future, // never completes
      );
      expect(r.isSuccess, isFalse);
      expect(r.failureReason, contains('timed out'));
    });
  });

  group('LadderResult.toDecision', () {
    test('returns a usable decision even when nothing succeeded', () {
      LadderResult result = LadderResult(
        chosen: null,
        attempts: <ProbeResult>[
          ProbeResult.failed(
            protocol: LinkProtocol.udp443,
            reason: 'x',
            elapsed: const Duration(milliseconds: 1),
          ),
          ProbeResult.failed(
            protocol: LinkProtocol.tcp443,
            reason: 'y',
            elapsed: const Duration(milliseconds: 1),
          ),
        ],
        totalElapsed: const Duration(milliseconds: 2),
      );
      LinkProtocolDecision d = result.toDecision();
      // Falls back to the last-attempted rung so the UI shows
      // something meaningful instead of a bogus "we chose UDP" message.
      expect(d.chosen, LinkProtocol.tcp443);
      expect(d.rejected, <LinkProtocol>[
        LinkProtocol.udp443,
        LinkProtocol.tcp443,
      ]);
    });
  });
}

void uiSuite() {
  group('DispatchColors.linkColorFor', () {
    test('returns the same color for the same linkId across calls', () {
      // The mapping is pure — required for the dashboard to read the same
      // color across the sparkline and link card stripe
      // rows for a given link.
      Color a = DispatchColors.linkColorFor('wifi-en0');
      Color b = DispatchColors.linkColorFor('wifi-en0');
      Color c = DispatchColors.linkColorFor('wifi-en0');
      expect(a, equals(b));
      expect(b, equals(c));
    });

    test('returns visibly different colors for different linkIds', () {
      // We don't lock the exact RGB values (that would over-constrain the
      // hash), but two unrelated link ids should land far apart on the hue
      // wheel. Compare hue distance >= 20 deg.
      Color a = DispatchColors.linkColorFor('wifi-en0');
      Color b = DispatchColors.linkColorFor('cell-pdp0');
      Color c = DispatchColors.linkColorFor('eth-en6');
      HSLColor ha = HSLColor.fromColor(a);
      HSLColor hb = HSLColor.fromColor(b);
      HSLColor hc = HSLColor.fromColor(c);
      expect(_hueDist(ha.hue, hb.hue), greaterThanOrEqualTo(20));
      expect(_hueDist(ha.hue, hc.hue), greaterThanOrEqualTo(20));
      expect(_hueDist(hb.hue, hc.hue), greaterThanOrEqualTo(20));
    });

    test('saturation and lightness are within the contrast window', () {
      // Saturation 0.6, lightness 0.45 chosen for readability on the panel
      // background. Confirm we always land in this band (allowing for the
      // small HSL → RGB → HSL round-trip drift that Flutter applies).
      for (String id in <String>[
        'a',
        'wifi-en0',
        'cell-pdp0',
        'eth-en6',
        'usb-tether-en8',
        'ethernet-en6',
        '🔥',
      ]) {
        HSLColor h = HSLColor.fromColor(DispatchColors.linkColorFor(id));
        expect(h.saturation, closeTo(0.60, 0.02));
        expect(h.lightness, closeTo(0.45, 0.02));
      }
    });

    test('an empty linkId returns a deterministic color', () {
      // Edge case — empty strings still need to round-trip cleanly so the
      // UI handles rows without a populated linkId without
      // crashing.
      Color a = DispatchColors.linkColorFor('');
      Color b = DispatchColors.linkColorFor('');
      expect(a, equals(b));
    });
  });
}

/// Shortest hue distance on a 0..360 wheel.
double _hueDist(double a, double b) {
  double diff = (a - b).abs();
  return diff > 180 ? 360 - diff : diff;
}

void widgetSuite() {
  late Directory tempDir;
  late Box settingsBox;
  DispatchController? controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('arcane_dispatch_test_');
    Hive.init(tempDir.path);
    settingsBox = await Hive.openBox('settings');
  });

  tearDown(() async {
    controller?.dispose();
    await settingsBox.close();
    await Hive.deleteFromDisk();
    await tempDir.delete(recursive: true);
  });

  testWidgets('starts proxy from selected interface', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      await settingsBox.put('selected_targets', <String>['en0']);
      // Pin transport_kind to socks so the controller renders the SOCKS
      // path. Production now defaults to the system-wide tunnel; this
      // widget test exercises the legacy proxy start path so the fake
      // transport's `Server` start is observable.
      await settingsBox.put('transport_kind', 'socks');
      // Disable captive-portal assist for this test. Production now
      // defaults it ON (so Wi-Fi networks stuck behind sign-in pages
      // automatically demote and the bond keeps moving), but the
      // detector spins up periodic timers that would trip the Flutter
      // widget-test "pending timers" guard. This test only exercises
      // the proxy-start path; the captive assist subsystem has its
      // own focused tests.
      Policy noCaptive = const Policy(
        mode: BondingMode.speed,
        captivePortalAssist: false,
      );
      await settingsBox.put('policy_v1', noCaptive.encode());
    });
    _FakeRepository repository = _FakeRepository();
    late _FakeServer server;
    controller = DispatchController(
      repository: repository,
      settingsBox: settingsBox,
      probeService: _NoopProbeService(),
      metricStore: LinkMetricStore(),
      // Inert naming service so the widget test doesn't trip the
      // pending-timer guard. Production wires the real macOS resolver
      // from `MainFlutterWindow.swift` -> `NetworkNamingHandler`.
      namingService: NetworkNamingService(
        fetcher: () async => const <NamedInterface>[],
        autoStart: false,
      ),
      transportFactory: (TransportKind kind, DispatchSettings settings) {
        return SocksTransport(
          repository: repository,
          serverFactory: (ProxyEventSink onEvent, ByteAccountant _) {
            server = _FakeServer(onEvent: onEvent);
            return server;
          },
          config: SocksTransportConfig(
            listenHost: settings.listenHost,
            listenPort: settings.listenPort,
          ),
        );
      },
    );
    await controller!.initialize();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildDispatchTheme(),
        home: DispatchHomeScreen(controller: controller!),
      ),
    );
    await tester.pump();

    expect(find.text('Arcane Dispatch'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);

    await tester.tap(find.text('Start'));
    await tester.pump();

    expect(server.started, isTrue);
    expect(server.addresses.single.ipv4!.address, '10.0.0.4');
    expect(find.text('Running'), findsOneWidget);

    // Stop the proxy before the test exits. The SOCKS transport now
    // runs a 1 Hz throughput emitter while running, and the Flutter
    // widget-test "pending timers" guard runs *before* tearDown gets a
    // chance to dispose the controller. Stopping here keeps the test
    // self-contained.
    await controller!.stopProxy();
    await tester.pump();
  });
}

class _FakeRepository extends NetworkInterfaceRepository {
  const _FakeRepository();

  @override
  Future<List<NetworkInterfaceSnapshot>> listUsableInterfaces() async {
    return <NetworkInterfaceSnapshot>[
      NetworkInterfaceSnapshot(
        name: 'en0',
        index: 1,
        addresses: <InternetAddress>[InternetAddress('10.0.0.4')],
      ),
    ];
  }
}

/// Probe service that does nothing — keeps the widget test free of pending
/// timers. The real service is exercised in `test/probes/*`.
class _NoopProbeService extends LinkProbeService {
  _NoopProbeService() : super();

  @override
  void updateLinks(List<Link> links) {}

  @override
  void updateInterfaces(List<NetworkInterfaceSnapshot> interfaces) {}

  @override
  void cancelTimers() {}

  @override
  Future<void> stop() async {}
}

class _FakeServer extends SocksProxyServer {
  bool started = false;
  List<ResolvedWeightedAddress> addresses = <ResolvedWeightedAddress>[];

  _FakeServer({super.onEvent});

  @override
  bool get isRunning {
    return started;
  }

  @override
  int? get boundPort {
    return 1080;
  }

  @override
  Future<void> start({
    required InternetAddress listenAddress,
    required int port,
    required List<ResolvedWeightedAddress> addresses,
  }) async {
    started = true;
    this.addresses = addresses;
  }

  @override
  Future<void> stop() async {
    started = false;
  }
}

void main() {
  group('bridge', bridgeSuite);
  group('protocol', protocolSuite);
  group('ui', uiSuite);
  group('widget', widgetSuite);
}
