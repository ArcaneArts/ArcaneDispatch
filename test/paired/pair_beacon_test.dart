import 'dart:async';

import 'package:arcane_dispatch/paired/pair_beacon.dart';
import 'package:flutter_test/flutter_test.dart';

PairBeacon _beacon(String id, {String host = '10.0.0.5', int port = 44430}) =>
    PairBeacon(
      deviceId: id,
      deviceName: 'Device-$id',
      host: host,
      port: port,
      fingerprint: 'abcd${id.padLeft(4, "0")}',
    );

void main() {
  group('LoopbackPairDiscovery', () {
    test('replays existing peers to new subscribers', () async {
      LoopbackPairRegistry registry = LoopbackPairRegistry();
      LoopbackPairDiscovery alice = LoopbackPairDiscovery(registry);
      LoopbackPairDiscovery bob = LoopbackPairDiscovery(registry);
      addTearDown(() async {
        await alice.dispose();
        await bob.dispose();
        await registry.dispose();
      });

      PairBeacon aBeacon = _beacon('alice');
      await alice.publish(aBeacon);

      List<PairBeaconEvent> events = <PairBeaconEvent>[];
      StreamSubscription<PairBeaconEvent> sub =
          bob.watch().listen(events.add);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events, hasLength(1));
      expect(events[0].type, PairBeaconEventType.found);
      expect(events[0].beacon.deviceId, 'alice');
    });

    test('streams future found/lost events to live subscribers', () async {
      LoopbackPairRegistry registry = LoopbackPairRegistry();
      LoopbackPairDiscovery host = LoopbackPairDiscovery(registry);
      LoopbackPairDiscovery joiner = LoopbackPairDiscovery(registry);
      addTearDown(() async {
        await host.dispose();
        await joiner.dispose();
        await registry.dispose();
      });

      List<PairBeaconEvent> seen = <PairBeaconEvent>[];
      StreamSubscription<PairBeaconEvent> sub =
          joiner.watch().listen(seen.add);

      await host.publish(_beacon('host-1'));
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.type, PairBeaconEventType.found);

      await host.unpublish();
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.type, PairBeaconEventType.lost);
      await sub.cancel();
    });

    test('hides self-publish events from local subscriber', () async {
      LoopbackPairRegistry registry = LoopbackPairRegistry();
      LoopbackPairDiscovery solo = LoopbackPairDiscovery(registry);
      addTearDown(() async {
        await solo.dispose();
        await registry.dispose();
      });

      await solo.publish(_beacon('solo'));

      List<PairBeacon> snapshot = solo.current;
      expect(snapshot, isEmpty);

      List<PairBeaconEvent> events = <PairBeaconEvent>[];
      StreamSubscription<PairBeaconEvent> sub =
          solo.watch().listen(events.add);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(events, isEmpty);
    });

    test('re-publish with new host:port emits a follow-up found event',
        () async {
      LoopbackPairRegistry registry = LoopbackPairRegistry();
      LoopbackPairDiscovery host = LoopbackPairDiscovery(registry);
      LoopbackPairDiscovery joiner = LoopbackPairDiscovery(registry);
      addTearDown(() async {
        await host.dispose();
        await joiner.dispose();
        await registry.dispose();
      });

      List<PairBeaconEvent> events = <PairBeaconEvent>[];
      StreamSubscription<PairBeaconEvent> sub =
          joiner.watch().listen(events.add);

      await host.publish(_beacon('host-x', host: '10.0.0.5'));
      await Future<void>.delayed(Duration.zero);

      await host.publish(_beacon('host-x', host: '10.0.0.6'));
      await Future<void>.delayed(Duration.zero);

      expect(events.length, 2);
      expect(events.every((PairBeaconEvent e) => e.type == PairBeaconEventType.found),
          isTrue);
      expect(events[1].beacon.host, '10.0.0.6');
      await sub.cancel();
    });
  });

  group('PairBeacon JSON round-trip', () {
    test('survives encode/decode', () {
      PairBeacon b = _beacon('123');
      PairBeacon round = PairBeacon.fromJson(b.toJson());
      expect(round.deviceId, b.deviceId);
      expect(round.deviceName, b.deviceName);
      expect(round.host, b.host);
      expect(round.port, b.port);
      expect(round.fingerprint, b.fingerprint);
      expect(round.version, b.version);
    });

    test('defaults missing fields safely', () {
      PairBeacon b = PairBeacon.fromJson(const <String, Object?>{});
      expect(b.deviceId, '');
      expect(b.host, '');
      expect(b.port, 44430);
      expect(b.version, '1');
    });
  });
}
