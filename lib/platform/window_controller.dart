import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'macos_tray_service.dart';

class WindowController {
  static const double defaultWidth = 500;
  static const double defaultHeight = 720;
  static const double trayOffset = 10;
  static const double visibleMargin = 8;
  static const String _trayIconAsset = 'assets/tray.png';

  static bool hideOnBlur = true;
  static StreamSubscription<MacOSTrayEvent>? _macOSSubscription;

  static WindowOptions get _windowOptions {
    return const WindowOptions(
      size: Size(defaultWidth, defaultHeight),
      minimumSize: Size(460, 620),
      maximumSize: Size(620, 900),
      center: false,
      title: 'Arcane Dispatch',
      backgroundColor: Color(0x00000000),
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
  }

  static Future<void> init({required bool initialHideOnBlur}) async {
    hideOnBlur = initialHideOnBlur;
    await windowManager.ensureInitialized();
    await _initTray();
    windowManager.addListener(_DispatchWindowListener());
    await windowManager.setPreventClose(true);
    await windowManager.waitUntilReadyToShow(_windowOptions, () async {
      await windowManager.hide();
      await windowManager.setBackgroundColor(Colors.transparent);
      if (Platform.isMacOS) {
        await windowManager.setMovable(false);
      }
      await windowManager.setAsFrameless();
      await windowManager.setHasShadow(false);
    });
  }

  static Future<void> _initTray() async {
    if (Platform.isMacOS) {
      _macOSSubscription ??= MacOSTrayService.instance.events.listen(
        _handleMacOSEvent,
      );
      await MacOSTrayService.instance.init();
      await MacOSTrayService.instance.setTooltip('Arcane Dispatch');
      return;
    }

    await trayManager.setIcon(_trayIconAsset, isTemplate: Platform.isMacOS);
    await trayManager.setToolTip('Arcane Dispatch');
    Menu menu = Menu(
      items: <MenuItem>[
        MenuItem(key: 'show', label: 'Show Arcane Dispatch'),
        MenuItem(key: 'hide', label: 'Hide Arcane Dispatch'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: 'Quit Arcane Dispatch'),
      ],
    );
    await trayManager.setContextMenu(menu);
    trayManager.addListener(_DispatchTrayListener());
  }

  static void _handleMacOSEvent(MacOSTrayEvent event) {
    if (event is MacOSTrayLeftClick) {
      unawaited(show());
      return;
    }
    if (event is MacOSTrayMenuItem) {
      if (event.key == 'show') {
        unawaited(show());
      } else if (event.key == 'hide') {
        unawaited(hide());
      } else if (event.key == 'exit') {
        unawaited(exitApp());
      }
    }
  }

  static Future<void> show() async {
    await _positionNearTray();
    await windowManager.show();
    await windowManager.focus();
  }

  static Future<void> hide() async {
    await windowManager.hide();
  }

  static Future<void> exitApp() async {
    await windowManager.destroy();
    exit(0);
  }

  static Future<void> _positionNearTray() async {
    List<Display> displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) {
      return;
    }
    Rect? trayBounds = Platform.isMacOS
        ? await MacOSTrayService.instance.getBounds()
        : await trayManager.getBounds();
    Display display = _displayForTrayBounds(trayBounds, displays);
    Rect visibleBounds = _visibleBoundsForDisplay(display);
    Size windowSize = await windowManager.getSize();
    Offset position = trayBounds == null || trayBounds.isEmpty
        ? _fallbackPosition(visibleBounds, windowSize)
        : _positionForTray(trayBounds, visibleBounds, windowSize);
    await windowManager.setPosition(position, animate: false);
  }

  static Display _displayForTrayBounds(
    Rect? trayBounds,
    List<Display> displays,
  ) {
    if (trayBounds == null || trayBounds.isEmpty) {
      return displays.first;
    }
    Offset center = trayBounds.center;
    Display best = displays.first;
    double bestDistance = double.infinity;
    for (Display display in displays) {
      Rect bounds = _visibleBoundsForDisplay(display);
      double dx = center.dx.clamp(bounds.left, bounds.right) - center.dx;
      double dy = center.dy.clamp(bounds.top, bounds.bottom) - center.dy;
      double distance = (dx * dx) + (dy * dy);
      if (distance < bestDistance) {
        best = display;
        bestDistance = distance;
      }
    }
    return best;
  }

  static Rect _visibleBoundsForDisplay(Display display) {
    Offset position = display.visiblePosition ?? Offset.zero;
    Size size = display.visibleSize ?? display.size;
    return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
  }

  static Offset _fallbackPosition(Rect visibleBounds, Size windowSize) {
    return Offset(
      (visibleBounds.right - windowSize.width - trayOffset).clamp(
        visibleBounds.left + visibleMargin,
        visibleBounds.right - windowSize.width - visibleMargin,
      ),
      (visibleBounds.top + trayOffset).clamp(
        visibleBounds.top + visibleMargin,
        visibleBounds.bottom - windowSize.height - visibleMargin,
      ),
    );
  }

  static Offset _positionForTray(
    Rect trayBounds,
    Rect visibleBounds,
    Size windowSize,
  ) {
    double x = trayBounds.center.dx - (windowSize.width / 2);
    double y = trayBounds.bottom + trayOffset;
    if (y + windowSize.height > visibleBounds.bottom) {
      y = trayBounds.top - windowSize.height - trayOffset;
    }
    return Offset(
      x.clamp(
        visibleBounds.left + visibleMargin,
        visibleBounds.right - windowSize.width - visibleMargin,
      ),
      y.clamp(
        visibleBounds.top + visibleMargin,
        visibleBounds.bottom - windowSize.height - visibleMargin,
      ),
    );
  }
}

class _DispatchTrayListener implements TrayListener {
  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      unawaited(WindowController.show());
    }
  }

  @override
  void onTrayIconMouseUp() {
    if (!Platform.isWindows) {
      unawaited(WindowController.show());
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    if (Platform.isWindows) {
      trayManager.popUpContextMenu();
    }
  }

  @override
  void onTrayIconRightMouseUp() {
    if (!Platform.isWindows) {
      trayManager.popUpContextMenu();
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show') {
      unawaited(WindowController.show());
    } else if (menuItem.key == 'hide') {
      unawaited(WindowController.hide());
    } else if (menuItem.key == 'exit') {
      unawaited(WindowController.exitApp());
    }
  }
}

class _DispatchWindowListener implements WindowListener {
  @override
  void onWindowBlur() {
    if (WindowController.hideOnBlur) {
      unawaited(WindowController.hide());
    }
  }

  @override
  void onWindowClose() {
    unawaited(WindowController.hide());
  }

  @override
  void onWindowDocked() {}

  @override
  void onWindowEnterFullScreen() {}

  @override
  void onWindowEvent(String eventName) {}

  @override
  void onWindowFocus() {}

  @override
  void onWindowLeaveFullScreen() {}

  @override
  void onWindowMaximize() {}

  @override
  void onWindowMinimize() {}

  @override
  void onWindowMove() {}

  @override
  void onWindowMoved() {}

  @override
  void onWindowResize() {}

  @override
  void onWindowResized() {}

  @override
  void onWindowRestore() {}

  @override
  void onWindowUndocked() {}

  @override
  void onWindowUnmaximize() {}
}
