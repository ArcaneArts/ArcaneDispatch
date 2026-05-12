import 'package:hive/hive.dart';

class DispatchSettings {
  final String listenHost;
  final int listenPort;
  final bool launchAtStartup;
  final bool startProxyOnLaunch;
  final bool hideOnBlur;
  final List<String> selectedTargets;

  const DispatchSettings({
    this.listenHost = '127.0.0.1',
    this.listenPort = 1080,
    this.launchAtStartup = false,
    this.startProxyOnLaunch = false,
    this.hideOnBlur = true,
    this.selectedTargets = const <String>[],
  });

  DispatchSettings copyWith({
    String? listenHost,
    int? listenPort,
    bool? launchAtStartup,
    bool? startProxyOnLaunch,
    bool? hideOnBlur,
    List<String>? selectedTargets,
  }) {
    return DispatchSettings(
      listenHost: listenHost ?? this.listenHost,
      listenPort: listenPort ?? this.listenPort,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      startProxyOnLaunch: startProxyOnLaunch ?? this.startProxyOnLaunch,
      hideOnBlur: hideOnBlur ?? this.hideOnBlur,
      selectedTargets: selectedTargets ?? this.selectedTargets,
    );
  }

  static DispatchSettings load(Box box) {
    List<String> targets = <String>[];
    Object? rawTargets = box.get('selected_targets');
    if (rawTargets is List) {
      targets = rawTargets.map((Object? value) => value.toString()).toList();
    }

    return DispatchSettings(
      listenHost: box.get('listen_host', defaultValue: '127.0.0.1').toString(),
      listenPort: _coercePort(box.get('listen_port'), fallback: 1080),
      launchAtStartup:
          box.get('launch_at_startup', defaultValue: false) == true,
      startProxyOnLaunch:
          box.get('start_proxy_on_launch', defaultValue: false) == true,
      hideOnBlur: box.get('hide_on_blur', defaultValue: true) == true,
      selectedTargets: targets,
    );
  }

  Future<void> save(Box box) async {
    await box.put('listen_host', listenHost);
    await box.put('listen_port', listenPort);
    await box.put('launch_at_startup', launchAtStartup);
    await box.put('start_proxy_on_launch', startProxyOnLaunch);
    await box.put('hide_on_blur', hideOnBlur);
    await box.put('selected_targets', selectedTargets);
  }

  static int _coercePort(Object? value, {required int fallback}) {
    if (value is int && value > 0 && value <= 65535) {
      return value;
    }
    if (value is String) {
      int? parsed = int.tryParse(value);
      if (parsed != null && parsed > 0 && parsed <= 65535) {
        return parsed;
      }
    }
    return fallback;
  }
}
