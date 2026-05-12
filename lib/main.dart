import 'dart:async';
import 'dart:io';

import 'package:fast_log/fast_log.dart' as fast_log;
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'core/network_interface_repository.dart';
import 'platform/startup_service.dart';
import 'platform/window_controller.dart';
import 'screen/dispatch_controller.dart';
import 'screen/home_screen.dart';
import 'ui/dispatch_ui.dart';

late String configPath;
late Box settingsBox;
late PackageInfo packageInfo;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await _initializeApp();
    DispatchController controller = DispatchController(
      repository: const NetworkInterfaceRepository(),
      settingsBox: settingsBox,
    );
    controller.addListener(() {
      WindowController.hideOnBlur = controller.settings.hideOnBlur;
    });
    unawaited(controller.initialize());
    runApp(DispatchApp(controller: controller));
  } catch (error, stackTrace) {
    fast_log.error('Fatal startup error: $error');
    fast_log.error('$stackTrace');
  }
}

Future<void> _initializeApp() async {
  fast_log.lDebugMode = true;
  Directory appDocDir = await getApplicationSupportDirectory();
  configPath = '${appDocDir.path}/ArcaneDispatch';
  await Directory(configPath).create(recursive: true);
  await _setupLogging();
  Hive.init(configPath);
  settingsBox = await Hive.openBox('settings');
  packageInfo = await PackageInfo.fromPlatform();
  StartupService.instance.setup(
    appName: 'Arcane Dispatch',
    appPath: Platform.resolvedExecutable,
  );
  await WindowController.init(
    initialHideOnBlur:
        settingsBox.get('hide_on_blur', defaultValue: true) == true,
  );
}

Future<void> _setupLogging() async {
  File logFile = File('$configPath/arcane_dispatch.log');
  if (await logFile.exists() && await logFile.length() > 1024 * 1024) {
    await logFile.delete();
  }
  IOSink sink = logFile.openWrite(mode: FileMode.writeOnlyAppend);
  fast_log.lLogHandler = (fast_log.LogCategory category, String message) {
    sink.writeln(
      '${DateTime.now().toIso8601String()} ${category.name}: $message',
    );
  };
}

class DispatchApp extends StatelessWidget {
  final DispatchController controller;

  const DispatchApp({required this.controller, super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Arcane Dispatch',
      theme: buildDispatchTheme(),
      home: DispatchHomeScreen(controller: controller),
    );
  }
}
