import 'dart:async';
import 'dart:typed_data';

import 'package:arcane_dispatch/crypto/noise.dart';
import 'package:arcane_dispatch/paired/pair_beacon.dart';
import 'package:arcane_dispatch/paired/pair_session.dart';
import 'package:arcane_dispatch/paired/paired_datagram.dart';
import 'package:arcane_dispatch/paired/paired_link_registry.dart';
import 'package:arcane_dispatch/paired/paired_link_socket.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PairedLinkRegistry', () {
    test('wrap routes paired link ids via socket and falls back otherwise',
        () async {
      // 1. Stand up a Noise transport pair via the loopback handshake.
      NoiseKeypair host = await NoiseKeypair.generate();
      NoiseKeypair joiner = await NoiseKeypair.generate();
      String hostFp = await PairSession.fingerprintOf(host.public);
      (LoopbackPairChannel, LoopbackPairChannel) ch = LoopbackPairChannel.pair();
      Future<PairOutcome> jFut = PairSession.join(
        channel: ch.$1,
        me: joiner,
        beacon: PairBeacon(
          deviceId: 'h',
          deviceName: 'H',
          host: '10.0.0.5',
          port: 44430,
          fingerprint: hostFp,
        ),
        remoteStatic: host.public,
      );
      Future<PairOutcome> hFut = PairSession.host(
        channel: ch.$2,
        me: host,
        hostName: 'H',
        endpoint: '10.0.0.5:44430',
        hostDeviceId: 'h',
      );
      List<PairOutcome> outcomes = await Future.wait(<Future<PairOutcome>>[
        jFut,
        hFut,
      ]);
      PairOutcome jo = outcomes[0];

      // 2. Build a paired link socket sitting on a loopback datagram.
      InMemoryDatagramRegistry reg = InMemoryDatagramRegistry();
      InMemoryPairedDatagram sock =
          InMemoryPairedDatagram(reg, host: '10.0.0.7', port: 33333);
      PairedLinkSocket link = PairedLinkSocket(
        socket: sock,
        transport: jo.transport,
        localDeviceId: 'j',
        peerHost: '10.0.0.5',
        peerPort: 44430,
      );

      // 3. Register with the registry under linkId "paired:h".
      PairedLinkRegistry registry = PairedLinkRegistry();
      registry.attach('paired:h', link);
      expect(registry.linkIds, contains('paired:h'));

      // 4. Build the wrapped sendOnLink.
      List<({String linkId, Uint8List bytes})> fallbackCalls =
          <({String linkId, Uint8List bytes})>[];
      void fallback(String id, Uint8List b) =>
          fallbackCalls.add((linkId: id, bytes: b));
      var wrapped = registry.wrap(fallback);

      // 5. Paired link goes through socket. Verify the bridge receives it.
      InMemoryPairedDatagram bridgeSock =
          InMemoryPairedDatagram(reg, host: '10.0.0.5', port: 44430);
      Completer<Uint8List> firstFrame = Completer<Uint8List>();
      bridgeSock.inbound.listen((PairedDatagramEvent e) {
        if (!firstFrame.isCompleted) firstFrame.complete(e.bytes);
      });
      wrapped('paired:h', Uint8List.fromList(<int>[7, 8, 9]));
      Uint8List wire = await firstFrame.future.timeout(
        const Duration(seconds: 1),
      );
      // header (8) + nonce (8) + ciphertext (3 + 16) = 35
      expect(wire.length, equals(35));
      expect(fallbackCalls, isEmpty);

      // 6. Non-paired link falls through to fallback.
      wrapped('local:en0', Uint8List.fromList(<int>[1, 2, 3]));
      expect(fallbackCalls, hasLength(1));
      expect(fallbackCalls.single.linkId, equals('local:en0'));
      expect(fallbackCalls.single.bytes, orderedEquals(<int>[1, 2, 3]));

      await link.close();
      await bridgeSock.close();
      await registry.dispose();
      await reg.dispose();
    });

    test('inbound stream tags events with the originating linkId', () async {
      // Pair handshake.
      NoiseKeypair host = await NoiseKeypair.generate();
      NoiseKeypair joiner = await NoiseKeypair.generate();
      String hostFp = await PairSession.fingerprintOf(host.public);
      (LoopbackPairChannel, LoopbackPairChannel) ch = LoopbackPairChannel.pair();
      Future<PairOutcome> jFut = PairSession.join(
        channel: ch.$1,
        me: joiner,
        beacon: PairBeacon(
          deviceId: 'h',
          deviceName: 'H',
          host: '10.0.0.5',
          port: 44430,
          fingerprint: hostFp,
        ),
        remoteStatic: host.public,
      );
      Future<PairOutcome> hFut = PairSession.host(
        channel: ch.$2,
        me: host,
        hostName: 'H',
        endpoint: '10.0.0.5:44430',
        hostDeviceId: 'h',
      );
      List<PairOutcome> outs = await Future.wait(<Future<PairOutcome>>[
        jFut,
        hFut,
      ]);
      PairOutcome jo = outs[0];
      PairOutcome ho = outs[1];

      InMemoryDatagramRegistry reg = InMemoryDatagramRegistry();
      InMemoryPairedDatagram jSock =
          InMemoryPairedDatagram(reg, host: '10.0.0.7', port: 33333);
      InMemoryPairedDatagram bSock =
          InMemoryPairedDatagram(reg, host: '10.0.0.5', port: 44430);
      PairedLinkSocket link = PairedLinkSocket(
        socket: jSock,
        transport: jo.transport,
        localDeviceId: 'j',
        peerHost: '10.0.0.5',
        peerPort: 44430,
      );

      PairedLinkRegistry registry = PairedLinkRegistry();
      registry.attach('paired:h', link);

      Completer<PairedInboundEvent> first = Completer<PairedInboundEvent>();
      registry.inbound.listen((PairedInboundEvent e) {
        if (!first.isCompleted) first.complete(e);
      });

      // Simulate the bridge shipping a sealed packet back.
      ({int nonce, Uint8List ciphertext}) sealed =
          await ho.transport.seal(null, Uint8List.fromList(<int>[33, 44]));
      Uint8List wire = Uint8List(16 + sealed.ciphertext.length);
      String dv = 'j';
      for (int i = 0; i < dv.length && i < 8; i++) {
        wire[i] = dv.codeUnitAt(i);
      }
      int n = sealed.nonce;
      for (int i = 7; i >= 0; i--) {
        wire[8 + i] = n & 0xff;
        n >>= 8;
      }
      wire.setRange(16, wire.length, sealed.ciphertext);
      await bSock.send(wire, toHost: '10.0.0.7', toPort: 33333);

      PairedInboundEvent evt =
          await first.future.timeout(const Duration(seconds: 1));
      expect(evt.linkId, equals('paired:h'));
      expect(evt.bytes, orderedEquals(<int>[33, 44]));

      await link.close();
      await bSock.close();
      await registry.dispose();
      await reg.dispose();
    });
  });
}
