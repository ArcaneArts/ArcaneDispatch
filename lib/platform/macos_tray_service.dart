import 'dart:async';

import 'package:flutter/services.dart';

sealed class MacOSTrayEvent {
  const MacOSTrayEvent();
}

class MacOSTrayLeftClick extends MacOSTrayEvent {
  const MacOSTrayLeftClick();
}

class MacOSTrayMenuItem extends MacOSTrayEvent {
  final String key;

  const MacOSTrayMenuItem(this.key);
}

class MacOSTrayService {
  static final MacOSTrayService instance = MacOSTrayService._();
  static const MethodChannel _channel = MethodChannel('dispatch_tray');

  final StreamController<MacOSTrayEvent> _events =
      StreamController<MacOSTrayEvent>.broadcast();
  bool _attached = false;

  MacOSTrayService._();

  Stream<MacOSTrayEvent> get events {
    return _events.stream;
  }

  Future<void> init() async {
    _attachHandler();
    try {
      await _channel.invokeMethod<void>('init');
    } on MissingPluginException {
      return;
    }
  }

  Future<Rect?> getBounds() async {
    try {
      Map<dynamic, dynamic>? data = await _channel
          .invokeMapMethod<dynamic, dynamic>('getBounds');
      if (data == null) {
        return null;
      }
      Object? rawX = data['x'];
      Object? rawY = data['y'];
      Object? rawWidth = data['width'];
      Object? rawHeight = data['height'];
      if (rawX is! num ||
          rawY is! num ||
          rawWidth is! num ||
          rawHeight is! num) {
        return null;
      }
      return Rect.fromLTWH(
        rawX.toDouble(),
        rawY.toDouble(),
        rawWidth.toDouble(),
        rawHeight.toDouble(),
      );
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> setTooltip(String tooltip) async {
    try {
      await _channel.invokeMethod<void>('setTooltip', <String, Object>{
        'tooltip': tooltip,
      });
    } on MissingPluginException {
      return;
    }
  }

  Future<void> setActivationPolicy(String mode) async {
    try {
      await _channel.invokeMethod<void>('setActivationPolicy', <String, Object>{
        'mode': mode,
      });
    } on MissingPluginException {
      return;
    }
  }

  Future<bool> quit() async {
    try {
      await _channel.invokeMethod<void>('quit');
      return true;
    } on MissingPluginException {
      return false;
    }
  }

  void _attachHandler() {
    if (_attached) {
      return;
    }
    _attached = true;
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onLeftClick') {
      _events.add(const MacOSTrayLeftClick());
      return null;
    }
    if (call.method == 'onMenuItem') {
      Object? arguments = call.arguments;
      String key = '';
      if (arguments is Map) {
        Object? rawKey = arguments['key'];
        if (rawKey is String) {
          key = rawKey;
        }
      }
      _events.add(MacOSTrayMenuItem(key));
      return null;
    }
    return null;
  }
}
