// Tests for `TunnelChannel.setServer` / `TunnelChannel.getServer`.
//
// Drives the real `MethodChannel` (no fake), but installs a custom
// platform handler so the test runs cross-platform. This is the layer we
// can't cover from `test/transport/tunnel_transport_test.dart` because
// that file substitutes the entire channel; here we exercise the actual
// dispatch into [MethodChannel.invokeMethod].

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/bridge/tunnel_channel.dart';

void main() {
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

  test('setServer encodes endpoint + token and round-trips a bool reply',
      () async {
    String? capturedEndpoint;
    String? capturedToken;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'setServer');
      Map<Object?, Object?> args = call.arguments as Map<Object?, Object?>;
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
  });

  test('setServer returns false when the platform replies non-true',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => false);
    bool ok = await client.setServer(endpoint: 'host:1', token: 't');
    expect(ok, isFalse);
  });

  test('setServer surfaces TunnelUnavailableException when no plugin',
      () async {
    // No handler installed => MissingPluginException.
    expect(
      () => client.setServer(endpoint: 'h', token: 't'),
      throwsA(isA<TunnelUnavailableException>()),
    );
  });

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
        <Object?, Object?>{});
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

  test('getClientPublicKey returns null when the platform returns null',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    String? pub = await client.getClientPublicKey();
    expect(pub, isNull);
  });

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
