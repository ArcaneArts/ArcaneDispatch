import 'dart:io';

import 'package:arcane_dispatch/core/network_interface_repository.dart';
import 'package:arcane_dispatch/core/socks_proxy_server.dart';
import 'package:arcane_dispatch/core/weighted_address.dart';
import 'package:arcane_dispatch/screen/dispatch_controller.dart';
import 'package:arcane_dispatch/screen/home_screen.dart';
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
    });
    _FakeServer server = _FakeServer();
    controller = DispatchController(
      repository: _FakeRepository(),
      settingsBox: settingsBox,
      server: server,
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
  });
}

class _FakeRepository extends NetworkInterfaceRepository {
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

class _FakeServer extends SocksProxyServer {
  bool started = false;
  List<ResolvedWeightedAddress> addresses = <ResolvedWeightedAddress>[];

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
