import 'dart:async';
import 'dart:typed_data';

import 'package:arcane_dispatch/crypto/noise.dart';
import 'package:arcane_dispatch/paired/pair_beacon.dart';
import 'package:arcane_dispatch/paired/pair_session.dart';
import 'package:arcane_dispatch/paired/paired_bridge.dart';
import 'package:arcane_dispatch/paired/paired_datagram.dart';
import 'package:arcane_dispatch/paired/paired_link_socket.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Pair & Share end-to-end (loopback)', () {
    test('round-trip: joiner -> bridge -> forwarder -> joiner', () async {
      // 1. Both sides generate static keys.
      NoiseKeypair hostStatic = await NoiseKeypair.generate();
      NoiseKeypair joinerStatic = await NoiseKeypair.generate();
      String hostFp = await PairSession.fingerprintOf(hostStatic.public);

      // 2. Run the pair handshake over a loopback channel.
      (LoopbackPairChannel, LoopbackPairChannel) chs =
          LoopbackPairChannel.pair();
      Future<PairOutcome> jFut = PairSession.join(
        channel: chs.$1,
        me: joinerStatic,
        beacon: PairBeacon(
          deviceId: 'host01',
          deviceName: 'Host',
          host: '10.0.0.5',
          port: 44430,
          fingerprint: hostFp,
        ),
        remoteStatic: hostStatic.public,
      );
      Future<PairOutcome> hFut = PairSession.host(
        channel: chs.$2,
        me: hostStatic,
        hostName: 'Host',
        endpoint: '10.0.0.5:44430',
        hostDeviceId: 'host01',
      );
      List<PairOutcome> outcomes = await Future.wait(<Future<PairOutcome>>[jFut, hFut]);
      PairOutcome jo = outcomes[0];
      PairOutcome ho = outcomes[1];
      expect(jo.verifyCode, equals(ho.verifyCode));

      // 3. Wire up the datagram fabric.
      InMemoryDatagramRegistry registry = InMemoryDatagramRegistry();
      InMemoryPairedDatagram bridgeSocket =
          InMemoryPairedDatagram(registry, host: '10.0.0.5', port: 44430);
      InMemoryPairedDatagram joinerSocket =
          InMemoryPairedDatagram(registry, host: '10.0.0.7', port: 55555);

      // 4. Stand up the bridge on the sharer.
      RecordingPairedBridgeForwarder fwd =
          RecordingPairedBridgeForwarder();
      PairedBridge bridge =
          PairedBridge(socket: bridgeSocket, forwarder: fwd);
      bridge.attachPeer(PairedPeerRoute(
        deviceId: 'joiner1',
        transport: ho.transport,
      ));
      await bridge.start();

      // 5. Joiner socket seals + ships frames.
      PairedLinkSocket link = PairedLinkSocket(
        socket: joinerSocket,
        transport: jo.transport,
        localDeviceId: 'joiner1',
        peerHost: '10.0.0.5',
        peerPort: 44430,
      );

      Uint8List packet = Uint8List.fromList(<int>[10, 20, 30, 40, 50]);
      await link.send(packet);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 6. Bridge forwarded the plaintext intact.
      expect(fwd.forwarded, hasLength(1));
      expect(fwd.forwarded.single, orderedEquals(packet));
      expect(fwd.fromDevices.single, equals('joiner1'));
      expect(bridge.stats.packetsAccepted, equals(1));
      expect(bridge.stats.packetsRejected, equals(0));
      expect(bridge.stats.packetsForwarded, equals(1));

      // 7. Inject a synthetic response and verify the joiner gets it.
      Uint8List reply = Uint8List.fromList(<int>[99, 88, 77]);
      Completer<Uint8List> got = Completer<Uint8List>();
      link.inbound.listen((Uint8List b) {
        if (!got.isCompleted) got.complete(b);
      });
      fwd.injectResponse(PairedBridgeResponse(
        toDeviceId: 'joiner1',
        bytes: reply,
      ));
      Uint8List received = await got.future.timeout(
        const Duration(seconds: 1),
      );
      expect(received, orderedEquals(reply));
      expect(bridge.stats.responsesShipped, equals(1));

      await link.close();
      await bridge.close();
      await registry.dispose();
    });

    test('unknown deviceId is rejected', () async {
      NoiseKeypair host = await NoiseKeypair.generate();
      InMemoryDatagramRegistry registry = InMemoryDatagramRegistry();
      InMemoryPairedDatagram socket =
          InMemoryPairedDatagram(registry, host: '10.0.0.5', port: 44430);
      InMemoryPairedDatagram attacker =
          InMemoryPairedDatagram(registry, host: '10.0.0.6', port: 33333);

      RecordingPairedBridgeForwarder fwd =
          RecordingPairedBridgeForwarder();
      PairedBridge bridge =
          PairedBridge(socket: socket, forwarder: fwd);
      // No peers attached. Any packet should be rejected.
      await bridge.start();

      // Pretend a stranger sends a well-formed but unknown-deviceId packet.
      Uint8List trash = Uint8List(8 + 8 + 32);
      // header = "unknown\0"
      const String dv = 'unknown';
      for (int i = 0; i < dv.length && i < 8; i++) {
        trash[i] = dv.codeUnitAt(i);
      }
      await attacker.send(trash,
          toHost: '10.0.0.5', toPort: 44430);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(bridge.stats.packetsAccepted, equals(0));
      expect(bridge.stats.packetsRejected, greaterThanOrEqualTo(1));
      expect(fwd.forwarded, isEmpty);

      // unused but verifies static keys still load
      expect(host.public.length, equals(32));

      await bridge.close();
      await registry.dispose();
    });

    test('replay (duplicated frame) is rejected', () async {
      NoiseKeypair hostStatic = await NoiseKeypair.generate();
      NoiseKeypair joinerStatic = await NoiseKeypair.generate();
      String hostFp = await PairSession.fingerprintOf(hostStatic.public);

      (LoopbackPairChannel, LoopbackPairChannel) chs =
          LoopbackPairChannel.pair();
      Future<PairOutcome> jFut = PairSession.join(
        channel: chs.$1,
        me: joinerStatic,
        beacon: PairBeacon(
          deviceId: 'host01',
          deviceName: 'Host',
          host: '10.0.0.5',
          port: 44430,
          fingerprint: hostFp,
        ),
        remoteStatic: hostStatic.public,
      );
      Future<PairOutcome> hFut = PairSession.host(
        channel: chs.$2,
        me: hostStatic,
        hostName: 'Host',
        endpoint: '10.0.0.5:44430',
        hostDeviceId: 'host01',
      );
      List<PairOutcome> outcomes =
          await Future.wait(<Future<PairOutcome>>[jFut, hFut]);
      PairOutcome jo = outcomes[0];
      PairOutcome ho = outcomes[1];

      InMemoryDatagramRegistry registry = InMemoryDatagramRegistry();
      InMemoryPairedDatagram bridgeSocket =
          InMemoryPairedDatagram(registry, host: '10.0.0.5', port: 44430);
      InMemoryPairedDatagram joinerSocket =
          InMemoryPairedDatagram(registry, host: '10.0.0.7', port: 55555);

      RecordingPairedBridgeForwarder fwd =
          RecordingPairedBridgeForwarder();
      PairedBridge bridge =
          PairedBridge(socket: bridgeSocket, forwarder: fwd);
      bridge.attachPeer(PairedPeerRoute(
        deviceId: 'joiner1',
        transport: ho.transport,
      ));
      await bridge.start();

      // Capture a sealed wire frame, then replay it manually.
      Uint8List packet = Uint8List.fromList(<int>[1, 2, 3]);
      ({int nonce, Uint8List ciphertext}) sealed =
          await jo.transport.seal(null, packet);
      Uint8List wire = Uint8List(16 + sealed.ciphertext.length);
      const String dv = 'joiner1';
      for (int i = 0; i < dv.length && i < 8; i++) {
        wire[i] = dv.codeUnitAt(i);
      }
      int n = sealed.nonce;
      for (int i = 7; i >= 0; i--) {
        wire[8 + i] = n & 0xff;
        n >>= 8;
      }
      wire.setRange(16, wire.length, sealed.ciphertext);

      await joinerSocket.send(wire, toHost: '10.0.0.5', toPort: 44430);
      await joinerSocket.send(wire, toHost: '10.0.0.5', toPort: 44430);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(bridge.stats.packetsAccepted, equals(1));
      expect(bridge.stats.packetsRejected, greaterThanOrEqualTo(1));
      expect(fwd.forwarded, hasLength(1));

      await bridge.close();
      await registry.dispose();
      await joinerSocket.close();
    });
  });
}
