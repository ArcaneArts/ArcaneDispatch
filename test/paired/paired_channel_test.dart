import 'package:arcane_dispatch/paired/pair_beacon.dart';
import 'package:arcane_dispatch/paired/paired_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel methodChannel = MethodChannel('dispatch_pair');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  test('publish forwards a beacon payload to the host', () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'publish') return true;
      if (call.method == 'snapshot') return <dynamic>[];
      return null;
    });

    final PairedMethodChannelDiscovery discovery =
        PairedMethodChannelDiscovery();
    await discovery.publish(const PairBeacon(
      deviceId: 'me-1',
      deviceName: 'Local Mac',
      host: '10.0.0.5',
      port: 44430,
      fingerprint: 'aaaabbbbccccdddd',
    ));

    expect(calls.length, equals(1));
    expect(calls.single.method, equals('publish'));
    Map args = calls.single.arguments as Map;
    expect(args['deviceId'], equals('me-1'));
    expect(args['fingerprint'], equals('aaaabbbbccccdddd'));

    await discovery.dispose();
  });

  test('snapshot returns parsed beacons and filters self', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
      if (call.method == 'snapshot') {
        return <dynamic>[
          <String, dynamic>{
            'deviceId': 'self',
            'deviceName': 'Me',
            'host': '127.0.0.1',
            'port': 44430,
            'fingerprint': 'aaaaaaaaaaaaaaaa',
          },
          <String, dynamic>{
            'deviceId': 'other',
            'deviceName': 'Peer',
            'host': '10.0.0.7',
            'port': 44430,
            'fingerprint': 'bbbbbbbbbbbbbbbb',
          },
        ];
      }
      return null;
    });

    final PairedMethodChannelDiscovery d = PairedMethodChannelDiscovery();
    await d.publish(const PairBeacon(
      deviceId: 'self',
      deviceName: 'Me',
      host: '127.0.0.1',
      port: 44430,
      fingerprint: 'aaaaaaaaaaaaaaaa',
    ));
    List<PairBeacon> peers = await d.refresh();
    expect(peers, hasLength(1));
    expect(peers.single.deviceId, equals('other'));
    await d.dispose();
  });

  test('missing platform plugin is treated as no peers', () async {
    // No mock set: MissingPluginException should bubble into an empty list.
    final PairedMethodChannelDiscovery d = PairedMethodChannelDiscovery();
    List<PairBeacon> peers = await d.refresh();
    expect(peers, isEmpty);
    await d.dispose();
  });
}
