import 'dart:convert';
import 'dart:io';

class StartupService {
  static final StartupService instance = StartupService._();

  String _appName = 'Arcane Dispatch';
  String _appPath = Platform.resolvedExecutable;
  String _label = 'art.arcane.ArcaneDispatch';

  StartupService._();

  void setup({
    required String appName,
    required String appPath,
    String label = 'art.arcane.ArcaneDispatch',
  }) {
    _appName = appName;
    _appPath = appPath;
    _label = label;
  }

  Future<bool> isEnabled() async {
    if (!Platform.isMacOS) {
      return false;
    }
    return File(_plistPath).exists();
  }

  Future<bool> enable() async {
    if (!Platform.isMacOS) {
      return false;
    }
    File plist = File(_plistPath);
    await plist.parent.create(recursive: true);
    await plist.writeAsString(_plistContents(), flush: true);
    await _runLaunchctl(<String>['bootstrap', _guiDomain, plist.path]);
    return true;
  }

  Future<bool> disable() async {
    if (!Platform.isMacOS) {
      return false;
    }
    File plist = File(_plistPath);
    await _runLaunchctl(<String>['bootout', _guiDomain, plist.path]);
    if (await plist.exists()) {
      await plist.delete();
    }
    return true;
  }

  String get _plistPath {
    String home = Platform.environment['HOME'] ?? Directory.current.path;
    return '$home/Library/LaunchAgents/$_label.plist';
  }

  String get _guiDomain {
    return 'gui/${_uid()}';
  }

  String _uid() {
    String? uid = Platform.environment['UID'];
    if (uid != null && uid.isNotEmpty) {
      return uid;
    }
    return Process.runSync('id', <String>['-u']).stdout.toString().trim();
  }

  Future<void> _runLaunchctl(List<String> args) async {
    try {
      await Process.run('launchctl', args);
    } catch (_) {
      return;
    }
  }

  String _plistContents() {
    String escapedName = const HtmlEscape().convert(_appName);
    String escapedPath = const HtmlEscape().convert(_appPath);
    String escapedLabel = const HtmlEscape().convert(_label);
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$escapedLabel</string>
  <key>ProgramArguments</key>
  <array>
    <string>$escapedPath</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/$escapedName.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/$escapedName.err.log</string>
</dict>
</plist>
''';
  }
}
