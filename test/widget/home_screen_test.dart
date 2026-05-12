import 'dart:io';

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
import 'package:arcane_dispatch/screen/dispatch_controller.dart';
import 'package:arcane_dispatch/screen/home_screen.dart';
import 'package:arcane_dispatch/transport/socks_transport.dart';
import 'package:arcane_dispatch/transport/transport.dart';
import 'package:arcane_dispatch/ui/dispatch_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
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
      // Disable Pair & Share for this widget test. Production wires a
      // real PairCoordinator via the default factory, which opens an
      // EventChannel subscription on `dispatch_pair/events` and spins
      // a Future<NoiseKeypair> in the background. Neither has a host
      // handler in the test harness, and the trailing event-channel
      // subscription is enough to wedge `tester.pump()` indefinitely
      // (no timers ever advance to a "settled" state). The Pair tab
      // gracefully renders a "Pairing is disabled" notice when the
      // coordinator is null, which is what we want here. The pair
      // path itself is exercised by dedicated tests under
      // `test/paired/*`.
      pairCoordinatorFactory: () => null,
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
