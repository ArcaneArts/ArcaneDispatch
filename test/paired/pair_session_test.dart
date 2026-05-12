import 'dart:async';
import 'dart:typed_data';

import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/crypto/noise.dart';
import 'package:arcane_dispatch/paired/pair_beacon.dart';
import 'package:arcane_dispatch/paired/pair_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PairSession (loopback)', () {
    test('handshake produces matching transports and verify codes', () async {
      NoiseKeypair host = await NoiseKeypair.generate();
      NoiseKeypair joiner = await NoiseKeypair.generate();

      String hostFp = await PairSession.fingerprintOf(host.public);
      PairBeacon beacon = PairBeacon(
        deviceId: 'host-1',
        deviceName: 'Studio Mac',
        host: '10.0.0.5',
        port: 44430,
        fingerprint: hostFp,
      );

      (LoopbackPairChannel, LoopbackPairChannel) channels =
          LoopbackPairChannel.pair();

      Future<PairOutcome> joinerFuture = PairSession.join(
        channel: channels.$1,
        me: joiner,
        beacon: beacon,
        remoteStatic: host.public,
      );
      Future<PairOutcome> hostFuture = PairSession.host(
        channel: channels.$2,
        me: host,
        hostName: 'Studio Mac',
        endpoint: '10.0.0.5:44430',
        hostDeviceId: 'host-1',
      );
      List<PairOutcome> results = await Future.wait<PairOutcome>(
          <Future<PairOutcome>>[joinerFuture, hostFuture]);
      PairOutcome jo = results[0];
      PairOutcome ho = results[1];

      expect(jo.verifyCode, equals(ho.verifyCode));
      expect(jo.verifyCode.length, equals(6));
      expect(jo.peerFingerprint, equals(hostFp));
      expect(jo.link.kind, equals(LinkKind.paired));
      expect(jo.link.pairedEndpoint, equals('10.0.0.5:44430'));
      expect(jo.link.pairedFingerprint, equals(hostFp));
      expect(ho.link.kind, equals(LinkKind.paired));
      expect(ho.link.pairedFingerprint, isNotEmpty);

      // Transport keys must mirror: host.send == joiner.recv and vice versa.
      Uint8List ping = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
      ({int nonce, Uint8List ciphertext}) sealed =
          await ho.transport.seal(null, ping);
      Uint8List opened =
          await jo.transport.open(sealed.nonce, null, sealed.ciphertext);
      expect(opened, orderedEquals(ping));
    });

    test('mismatched advertised fingerprint aborts the joiner', () async {
      NoiseKeypair host = await NoiseKeypair.generate();
      NoiseKeypair joiner = await NoiseKeypair.generate();

      // The beacon claims a different fingerprint than the real key.
      PairBeacon beacon = const PairBeacon(
        deviceId: 'host-2',
        deviceName: 'Tampered',
        host: '10.0.0.6',
        port: 44430,
        fingerprint: 'ffffffffffffffff',
      );

      (LoopbackPairChannel, LoopbackPairChannel) channels =
          LoopbackPairChannel.pair();

      Future<PairOutcome> joinerFuture = PairSession.join(
        channel: channels.$1,
        me: joiner,
        beacon: beacon,
        remoteStatic: host.public,
      );
      Future<PairOutcome> hostFuture = PairSession.host(
        channel: channels.$2,
        me: host,
        hostName: 'Tampered',
        endpoint: '10.0.0.6:44430',
      );

      // Host completes its half; joiner throws.
      await expectLater(joinerFuture, throwsA(isA<PairException>()));
      await hostFuture; // drain
    });

    test('initiator timeout surfaces a PairException', () async {
      NoiseKeypair joiner = await NoiseKeypair.generate();
      NoiseKeypair phantomHost = await NoiseKeypair.generate();
      (LoopbackPairChannel, LoopbackPairChannel) channels =
          LoopbackPairChannel.pair();

      Future<PairOutcome> joinerFuture = PairSession.join(
        channel: channels.$1,
        me: joiner,
        beacon: PairBeacon(
          deviceId: 'phantom',
          deviceName: 'Ghost',
          host: '10.0.0.9',
          port: 44430,
          fingerprint:
              await PairSession.fingerprintOf(phantomHost.public),
        ),
        remoteStatic: phantomHost.public,
        timeout: const Duration(milliseconds: 50),
      );

      await expectLater(joinerFuture, throwsA(isA<PairException>()));
    });
  });

  group('LoopbackPairDiscovery', () {
    test('two instances on the same registry see each other', () async {
      LoopbackPairRegistry reg = LoopbackPairRegistry();
      LoopbackPairDiscovery a = LoopbackPairDiscovery(reg);
      LoopbackPairDiscovery b = LoopbackPairDiscovery(reg);

      Future<PairBeaconEvent> nextA = a.watch().first;
      await b.publish(const PairBeacon(
        deviceId: 'b',
        deviceName: 'B',
        host: '127.0.0.2',
        port: 44430,
        fingerprint: 'bbbbbbbbbbbbbbbb',
      ));
      PairBeaconEvent evtA =
          await nextA.timeout(const Duration(seconds: 1));
      expect(evtA.type, equals(PairBeaconEventType.found));
      expect(evtA.beacon.deviceId, equals('b'));

      await b.dispose();
      await a.dispose();
      await reg.dispose();
    });

    test('publisher does not see its own beacon', () async {
      LoopbackPairRegistry reg = LoopbackPairRegistry();
      LoopbackPairDiscovery a = LoopbackPairDiscovery(reg);

      await a.publish(const PairBeacon(
        deviceId: 'a',
        deviceName: 'A',
        host: '127.0.0.1',
        port: 44430,
        fingerprint: 'aaaaaaaaaaaaaaaa',
      ));
      List<PairBeacon> seen = a.current;
      expect(seen, isEmpty);

      await a.dispose();
      await reg.dispose();
    });

    test('unregister emits lost event', () async {
      LoopbackPairRegistry reg = LoopbackPairRegistry();
      LoopbackPairDiscovery a = LoopbackPairDiscovery(reg);
      LoopbackPairDiscovery b = LoopbackPairDiscovery(reg);

      Completer<PairBeaconEvent> firstLost =
          Completer<PairBeaconEvent>();
      StreamSubscription<PairBeaconEvent> sub = a.watch().listen((event) {
        if (event.type == PairBeaconEventType.lost && !firstLost.isCompleted) {
          firstLost.complete(event);
        }
      });

      await b.publish(const PairBeacon(
        deviceId: 'transient',
        deviceName: 'Tran',
        host: '127.0.0.3',
        port: 44430,
        fingerprint: 'cccccccccccccccc',
      ));
      await b.unpublish();
      PairBeaconEvent evt =
          await firstLost.future.timeout(const Duration(seconds: 1));
      expect(evt.beacon.deviceId, equals('transient'));

      await sub.cancel();
      await a.dispose();
      await b.dispose();
      await reg.dispose();
    });
  });
}
