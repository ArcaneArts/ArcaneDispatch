import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../core/dispatch_settings.dart';
import '../core/network_interface_repository.dart';
import '../core/proxy_event.dart';
import '../core/socks_proxy_server.dart';
import '../core/weighted_address.dart';
import '../platform/startup_service.dart';

class DispatchController extends ChangeNotifier {
  final NetworkInterfaceRepository repository;
  final Box settingsBox;
  late final SocksProxyServer server;
  final WeightedAddressResolver resolver;

  DispatchSettings settings;
  List<NetworkInterfaceSnapshot> interfaces = <NetworkInterfaceSnapshot>[];
  List<ProxyEvent> events = <ProxyEvent>[];
  bool loadingInterfaces = false;
  String? errorText;

  DispatchController({
    required this.repository,
    required this.settingsBox,
    SocksProxyServer? server,
    this.resolver = const WeightedAddressResolver(),
  }) : settings = DispatchSettings.load(settingsBox) {
    this.server = server ?? SocksProxyServer(onEvent: addEvent);
  }

  bool get isRunning {
    return server.isRunning;
  }

  String get proxyEndpoint {
    return '${settings.listenHost}:${server.boundPort ?? settings.listenPort}';
  }

  Future<void> initialize() async {
    await refreshInterfaces();
    if (settings.startProxyOnLaunch && settings.selectedTargets.isNotEmpty) {
      await startProxy();
    }
  }

  Future<void> refreshInterfaces() async {
    loadingInterfaces = true;
    errorText = null;
    notifyListeners();
    try {
      interfaces = await repository.listUsableInterfaces();
    } catch (error) {
      errorText = 'Failed to read network interfaces: $error';
    } finally {
      loadingInterfaces = false;
      notifyListeners();
    }
  }

  Future<void> setListenHost(String host) async {
    settings = settings.copyWith(listenHost: host.trim());
    await settings.save(settingsBox);
    notifyListeners();
  }

  Future<void> setListenPort(String value) async {
    int? port = int.tryParse(value.trim());
    if (port == null || port < 1 || port > 65535) {
      errorText = 'Port must be between 1 and 65535.';
      notifyListeners();
      return;
    }
    settings = settings.copyWith(listenPort: port);
    await settings.save(settingsBox);
    errorText = null;
    notifyListeners();
  }

  Future<void> setLaunchAtStartup(bool value) async {
    settings = settings.copyWith(launchAtStartup: value);
    await settings.save(settingsBox);
    if (value) {
      await StartupService.instance.enable();
    } else {
      await StartupService.instance.disable();
    }
    notifyListeners();
  }

  Future<void> setStartProxyOnLaunch(bool value) async {
    settings = settings.copyWith(startProxyOnLaunch: value);
    await settings.save(settingsBox);
    notifyListeners();
  }

  Future<void> setHideOnBlur(bool value) async {
    settings = settings.copyWith(hideOnBlur: value);
    await settings.save(settingsBox);
    notifyListeners();
  }

  Future<void> setTargetSelected(String target, bool selected) async {
    Set<String> next = settings.selectedTargets.toSet();
    if (selected) {
      next.add(target);
    } else {
      next.remove(target);
    }
    settings = settings.copyWith(selectedTargets: next.toList()..sort());
    await settings.save(settingsBox);
    notifyListeners();
  }

  Future<void> startProxy() async {
    if (server.isRunning) {
      return;
    }
    errorText = null;
    notifyListeners();
    try {
      List<RawWeightedAddress> raw = settings.selectedTargets
          .map(RawWeightedAddress.parse)
          .toList();
      List<ResolvedWeightedAddress> resolved = resolver.resolve(
        raw,
        interfaces,
      );
      await server.start(
        listenAddress: InternetAddress(settings.listenHost),
        port: settings.listenPort,
        addresses: resolved,
      );
    } catch (error) {
      errorText = error.toString();
      addEvent(ProxyEvent(type: ProxyEventType.error, message: errorText!));
    }
    notifyListeners();
  }

  Future<void> stopProxy() async {
    if (!server.isRunning) {
      return;
    }
    await server.stop();
    notifyListeners();
  }

  void addEvent(ProxyEvent event) {
    events = <ProxyEvent>[event, ...events].take(80).toList();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(server.stop());
    super.dispose();
  }
}
