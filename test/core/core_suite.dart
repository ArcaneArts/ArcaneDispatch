import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:arcane_dispatch/core/bonding_mode.dart';
import 'package:arcane_dispatch/core/dispatch_settings.dart';
import 'package:arcane_dispatch/core/link_metric.dart';
import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/network_interface_repository.dart';
import 'package:arcane_dispatch/core/policy.dart';
import 'package:arcane_dispatch/core/proxy_event.dart';
import 'package:arcane_dispatch/core/socks_proxy_server.dart';
import 'package:arcane_dispatch/core/weighted_address.dart';
import 'package:arcane_dispatch/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void corePolicySuite() {
  group('Link', () {
    test('parses legacy "<target>" tokens', () {
      Link link = Link.fromLegacyTarget('en0');
      expect(link.id, 'legacy:en0');
      expect(link.label, 'en0');
      expect(link.interfaceName, 'en0');
      expect(link.sourceAddress, isNull);
      expect(link.weight, 1);
      expect(link.priority, LinkPriority.primary);
    });

    test('parses legacy "<target>/<weight>" tokens', () {
      Link link = Link.fromLegacyTarget('en0/4');
      expect(link.interfaceName, 'en0');
      expect(link.weight, 4);
    });

    test('parses legacy IP-literal tokens as sourceAddress', () {
      Link link = Link.fromLegacyTarget('10.0.0.14/2');
      expect(link.interfaceName, isNull);
      expect(link.sourceAddress, '10.0.0.14');
      expect(link.weight, 2);
    });

    test('toLegacyTarget round-trips through fromLegacyTarget', () {
      for (String token in const <String>[
        'en0',
        'en0/3',
        '10.0.0.14',
        '10.0.0.14/2',
      ]) {
        Link link = Link.fromLegacyTarget(token);
        expect(link.toLegacyTarget(), token);
      }
    });

    test('JSON round-trip preserves every field', () {
      Link link = Link(
        id: 'link-1',
        label: 'Wi-Fi',
        interfaceName: 'en0',
        sourceAddress: '10.0.0.14',
        priority: LinkPriority.backup,
        weight: 5,
        speedCapBps: 1024 * 1024,
        dataCapBytes: 5 * 1024 * 1024 * 1024,
        dataUsedBytes: 100,
        billingCycleAnchor: '2026-05-01',
        status: LinkStatus.degraded,
      );
      Link decoded = Link.fromJson(link.toJson());
      expect(decoded.id, link.id);
      expect(decoded.label, link.label);
      expect(decoded.interfaceName, link.interfaceName);
      expect(decoded.sourceAddress, link.sourceAddress);
      expect(decoded.priority, link.priority);
      expect(decoded.weight, link.weight);
      expect(decoded.speedCapBps, link.speedCapBps);
      expect(decoded.dataCapBytes, link.dataCapBytes);
      expect(decoded.dataUsedBytes, link.dataUsedBytes);
      expect(decoded.billingCycleAnchor, link.billingCycleAnchor);
      expect(decoded.status, link.status);
    });

    test('copyWith treats null sentinels as "clear field"', () {
      Link link = Link(
        id: 'l',
        label: 'l',
        interfaceName: 'en0',
        sourceAddress: '10.0.0.1',
      );
      Link cleared = link.copyWith(interfaceName: null, sourceAddress: null);
      expect(cleared.interfaceName, isNull);
      expect(cleared.sourceAddress, isNull);
    });

    test('encode + decode is lossless', () {
      Link link = Link(
        id: 'x',
        label: 'X',
        interfaceName: 'en1',
        priority: LinkPriority.secondary,
        weight: 7,
      );
      Link round = Link.decode(link.encode());
      expect(round.id, link.id);
      expect(round.interfaceName, 'en1');
      expect(round.priority, LinkPriority.secondary);
      expect(round.weight, 7);
    });
  });

  group('Policy', () {
    Link link(String id, LinkPriority p) {
      return Link(id: id, label: id, interfaceName: id, priority: p);
    }

    test('linksByPriority groups in priority order, preserves entry order', () {
      Policy policy = Policy(
        links: <Link>[
          link('a', LinkPriority.secondary),
          link('b', LinkPriority.primary),
          link('c', LinkPriority.primary),
          link('d', LinkPriority.never),
        ],
      );
      Map<LinkPriority, List<Link>> grouped = policy.linksByPriority();
      expect(grouped[LinkPriority.primary]!.map((Link l) => l.id), <String>[
        'b',
        'c',
      ]);
      expect(grouped[LinkPriority.secondary]!.map((Link l) => l.id), <String>[
        'a',
      ]);
      expect(grouped[LinkPriority.backup], isEmpty);
      expect(grouped[LinkPriority.never]!.map((Link l) => l.id), <String>['d']);
    });

    test('linkById returns matching link or null', () {
      Policy policy = Policy(links: <Link>[link('a', LinkPriority.primary)]);
      expect(policy.linkById('a')!.id, 'a');
      expect(policy.linkById('zzz'), isNull);
    });

    test('JSON round-trip preserves links + mode + flags', () {
      Policy policy = Policy(
        mode: BondingMode.redundant,
        killSwitch: true,
        dnsServers: const <String>['1.1.1.1', '9.9.9.9'],
        splitTunnelAllowList: const <String>['internal.corp'],
        serverUrl: 'udp://relay.example.com:443',
        serverToken: 'tok',
        links: <Link>[link('a', LinkPriority.primary)],
      );
      Policy decoded = Policy.fromJson(policy.toJson());
      expect(decoded.mode, BondingMode.redundant);
      expect(decoded.killSwitch, isTrue);
      expect(decoded.dnsServers, <String>['1.1.1.1', '9.9.9.9']);
      expect(decoded.splitTunnelAllowList, <String>['internal.corp']);
      expect(decoded.serverUrl, 'udp://relay.example.com:443');
      expect(decoded.serverToken, 'tok');
      expect(decoded.links.single.id, 'a');
    });

    test('copyWith sentinel allows clearing serverUrl/serverToken', () {
      Policy policy = Policy(serverUrl: 'a', serverToken: 'b');
      Policy cleared = policy.copyWith(serverUrl: null, serverToken: null);
      expect(cleared.serverUrl, isNull);
      expect(cleared.serverToken, isNull);
    });

    test('decode tolerates unknown mode by falling back to speed', () {
      Policy policy = Policy.fromJson(<String, Object?>{'mode': 'not-a-mode'});
      expect(policy.mode, BondingMode.speed);
    });
  });

  group('BondingModeCodec', () {
    test('round-trips all known modes', () {
      for (BondingMode mode in BondingMode.values) {
        expect(BondingModeCodec.parse(mode.wireName), mode);
      }
    });

    test('falls back to default on unknown wire string', () {
      expect(BondingModeCodec.parse('bogus'), BondingMode.speed);
      expect(
        BondingModeCodec.parse(null, fallback: BondingMode.redundant),
        BondingMode.redundant,
      );
    });
  });

  group('LinkPriorityCodec', () {
    test('round-trips all known priorities', () {
      for (LinkPriority priority in LinkPriority.values) {
        expect(LinkPriorityCodec.parse(priority.wireName), priority);
      }
    });
  });

  group('LinkMetric.estimateMos', () {
    test('ideal conditions score near 4.4', () {
      double mos = LinkMetric.estimateMos(rttMs: 5, jitterMs: 1, lossPct: 0);
      expect(mos, greaterThan(4.0));
      expect(mos, lessThanOrEqualTo(4.5));
    });

    test('severe loss collapses MOS toward 1.0', () {
      double mos = LinkMetric.estimateMos(
        rttMs: 200,
        jitterMs: 50,
        lossPct: 30,
      );
      expect(mos, lessThan(2.5));
      expect(mos, greaterThanOrEqualTo(1.0));
    });

    test('withDerivedMos fills mos when missing', () {
      LinkMetric raw = LinkMetric(
        linkId: 'l',
        capturedAt: DateTime.utc(2026, 5, 11),
        rttMs: 20,
        jitterMs: 2,
        loss: 0.01,
      );
      LinkMetric enriched = raw.withDerivedMos();
      expect(enriched.mos, isNotNull);
      expect(enriched.mos, greaterThan(3.5));
    });

    test('withDerivedMos is a no-op when mos already set', () {
      LinkMetric pre = LinkMetric(
        linkId: 'l',
        capturedAt: DateTime.utc(2026, 5, 11),
        mos: 2.0,
      );
      expect(identical(pre.withDerivedMos(), pre), isTrue);
    });
  });

  group('DispatchSettings', () {
    late Directory tempDir;
    late Box box;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('arcane_dispatch_test_');
      Hive.init(tempDir.path);
      box = await Hive.openBox('settings');
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteFromDisk();
      await tempDir.delete(recursive: true);
    });

    test('default load returns sane empty settings', () {
      DispatchSettings s = DispatchSettings.load(box);
      expect(s.listenHost, '127.0.0.1');
      expect(s.listenPort, 1080);
      // System-wide tunnel is now the default — the product is meant
      // to behave like Speedify (covers every app on the machine) out
      // of the box.
      expect(s.transportKind, TransportKind.tunnel);
      expect(s.links, isEmpty);
      expect(s.policy.mode, BondingMode.speed);
      expect(s.policy.links, isEmpty);
      expect(s.policy.serverUrl, DispatchSettings.defaultRelayUrl);
      expect(s.policy.serverToken, DispatchSettings.defaultRelayToken);
      expect(s.policy.bondedTransport, isTrue);
    });

    test('migrates legacy selected_targets into links_v1', () async {
      await box.put('selected_targets', <String>['en0', '10.0.0.4/2']);
      DispatchSettings s = DispatchSettings.load(box);
      expect(s.links.length, 2);
      expect(s.links[0].interfaceName, 'en0');
      expect(s.links[1].sourceAddress, '10.0.0.4');
      expect(s.links[1].weight, 2);
      expect(s.selectedTargets, <String>['en0', '10.0.0.4/2']);
    });

    test('save then load preserves links + policy', () async {
      DispatchSettings original = DispatchSettings(
        listenHost: '127.0.0.1',
        listenPort: 1080,
        transportKind: TransportKind.tunnel,
        links: <Link>[
          Link(id: 'l1', label: 'Wi-Fi', interfaceName: 'en0', weight: 3),
        ],
        policy: Policy(mode: BondingMode.redundant, killSwitch: true),
      );
      await original.save(box);

      DispatchSettings loaded = DispatchSettings.load(box);
      expect(loaded.transportKind, TransportKind.tunnel);
      expect(loaded.links.single.id, 'l1');
      expect(loaded.links.single.weight, 3);
      expect(loaded.policy.mode, BondingMode.redundant);
      expect(loaded.policy.killSwitch, isTrue);
      // Policy.links should be re-synced with the freshly-read link list.
      expect(loaded.policy.links.single.id, 'l1');
      expect(loaded.policy.serverUrl, DispatchSettings.defaultRelayUrl);
      expect(loaded.policy.serverToken, DispatchSettings.defaultRelayToken);
      expect(loaded.policy.bondedTransport, isTrue);
    });

    test('load forces saved relay config back to the SLC default', () async {
      Policy stale = const Policy(
        serverUrl: 'udp://old.example.com:4430',
        serverToken: 'old-token',
        bondedTransport: false,
      );
      await box.put('policy_v1', stale.encode());

      DispatchSettings loaded = DispatchSettings.load(box);
      expect(loaded.policy.serverUrl, DispatchSettings.defaultRelayUrl);
      expect(loaded.policy.serverToken, DispatchSettings.defaultRelayToken);
      expect(loaded.policy.bondedTransport, isTrue);
    });

    test('load and save keep connect-on-launch disabled', () async {
      await box.put('start_proxy_on_launch', true);

      DispatchSettings loaded = DispatchSettings.load(box);
      expect(loaded.startProxyOnLaunch, isFalse);

      await loaded.copyWith(startProxyOnLaunch: true).save(box);
      expect(box.get('start_proxy_on_launch'), isFalse);
    });

    test('save mirrors selectedTargets back to legacy key', () async {
      DispatchSettings s = DispatchSettings(
        links: <Link>[Link.fromLegacyTarget('en0/2')],
      );
      await s.save(box);
      Object? legacy = box.get('selected_targets');
      expect(legacy, isA<List<Object?>>());
      expect(
        (legacy as List).map((Object? e) => e.toString()).toList(),
        <String>['en0/2'],
      );
    });

    test('copyWithSelectedTargets keeps links + policy aligned', () {
      DispatchSettings s = const DispatchSettings();
      DispatchSettings next = s.copyWithSelectedTargets(<String>[
        'en0',
        '10.0.0.4/2',
      ]);
      expect(next.links.length, 2);
      expect(next.policy.links.length, 2);
      expect(next.selectedTargets, <String>['en0', '10.0.0.4/2']);
      // never-priority links are excluded from selectedTargets
      DispatchSettings withDisabled = next.copyWith(
        links: <Link>[
          next.links[0].copyWith(priority: LinkPriority.never),
          next.links[1],
        ],
      );
      expect(withDisabled.selectedTargets, <String>['10.0.0.4/2']);
    });

    test('TransportKindCodec parses unknown strings to fallback', () {
      expect(TransportKindCodec.parse('socks'), TransportKind.socks);
      expect(TransportKindCodec.parse('tunnel'), TransportKind.tunnel);
      // Default fallback is the system-wide tunnel now.
      expect(TransportKindCodec.parse('bogus'), TransportKind.tunnel);
      expect(
        TransportKindCodec.parse(null, fallback: TransportKind.socks),
        TransportKind.socks,
      );
    });
  });
}

void coreSocksProxyServerSuite() {
  test(
    'proxies SOCKS5 connect traffic through selected source address',
    () async {
      _EchoServer echo = await _EchoServer.start();
      SocksProxyServer proxy = SocksProxyServer();
      await proxy.start(
        listenAddress: InternetAddress.loopbackIPv4,
        port: 0,
        addresses: <ResolvedWeightedAddress>[
          ResolvedWeightedAddress(
            label: 'loopback',
            weight: 1,
            ipv4: InternetAddress.loopbackIPv4,
          ),
        ],
      );

      Socket client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        proxy.boundPort!,
      );
      _SocketReader reader = _SocketReader(client);

      client.add(<int>[0x05, 0x01, 0x00]);
      await client.flush();
      expect(await reader.readExact(2), <int>[0x05, 0x00]);

      client.add(<int>[
        0x05,
        0x01,
        0x00,
        0x01,
        127,
        0,
        0,
        1,
        echo.port >> 8,
        echo.port & 0xff,
      ]);
      await client.flush();
      List<int> status = await reader.readExact(10);
      expect(status[1], 0x00);

      client.add(utf8.encode('ping'));
      await client.flush();
      expect(utf8.decode(await reader.readExact(4)), 'ping');

      client.destroy();
      await proxy.stop();
      await echo.stop();
    },
  );

  test('proxies SOCKS4 connect traffic', () async {
    _EchoServer echo = await _EchoServer.start();
    SocksProxyServer proxy = SocksProxyServer();
    await proxy.start(
      listenAddress: InternetAddress.loopbackIPv4,
      port: 0,
      addresses: <ResolvedWeightedAddress>[
        ResolvedWeightedAddress(
          label: 'loopback',
          weight: 1,
          ipv4: InternetAddress.loopbackIPv4,
        ),
      ],
    );

    Socket client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.boundPort!,
    );
    _SocketReader reader = _SocketReader(client);

    client.add(<int>[
      0x04,
      0x01,
      echo.port >> 8,
      echo.port & 0xff,
      127,
      0,
      0,
      1,
      0x00,
    ]);
    await client.flush();
    List<int> status = await reader.readExact(8);
    expect(status[1], 0x5a);

    client.add(utf8.encode('pong'));
    await client.flush();
    expect(utf8.decode(await reader.readExact(4)), 'pong');

    client.destroy();
    await proxy.stop();
    await echo.stop();
  });

  test(
    'stall watchdog tears down connection when both directions go silent',
    () async {
      _EchoServer echo = await _EchoServer.start();
      List<ProxyEvent> events = <ProxyEvent>[];
      SocksProxyServer proxy = SocksProxyServer(
        onEvent: events.add,
        stallTimeout: const Duration(milliseconds: 250),
      );
      await proxy.start(
        listenAddress: InternetAddress.loopbackIPv4,
        port: 0,
        addresses: <ResolvedWeightedAddress>[
          ResolvedWeightedAddress(
            label: 'loopback',
            weight: 1,
            ipv4: InternetAddress.loopbackIPv4,
          ),
        ],
      );

      Socket client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        proxy.boundPort!,
      );
      _SocketReader reader = _SocketReader(client);

      // SOCKS5 handshake + CONNECT to echo, but never send any payload so the
      // pipe sees no traffic in either direction.
      client.add(<int>[0x05, 0x01, 0x00]);
      await client.flush();
      expect(await reader.readExact(2), <int>[0x05, 0x00]);
      client.add(<int>[
        0x05,
        0x01,
        0x00,
        0x01,
        127,
        0,
        0,
        1,
        echo.port >> 8,
        echo.port & 0xff,
      ]);
      await client.flush();
      List<int> status = await reader.readExact(10);
      expect(status[1], 0x00);

      // Wait until the proxy emits the closure event for our connection.
      // The watchdog fires every stallTimeout/2 = 125ms; allow ~1s for the
      // teardown round-trip on slow CI.
      DateTime deadline = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(deadline) &&
          !events.any(
            (ProxyEvent e) =>
                e.type == ProxyEventType.warning &&
                e.message.contains('stalled'),
          )) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      expect(
        events.any(
          (ProxyEvent e) =>
              e.type == ProxyEventType.warning && e.message.contains('stalled'),
        ),
        isTrue,
        reason: 'expected stall watchdog to emit a warning event',
      );

      client.destroy();
      await proxy.stop();
      await echo.stop();
    },
  );
}

class _EchoServer {
  final ServerSocket server;
  final List<StreamSubscription<Uint8List>> subscriptions;

  _EchoServer(this.server, this.subscriptions);

  int get port {
    return server.port;
  }

  static Future<_EchoServer> start() async {
    ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    List<StreamSubscription<Uint8List>> subscriptions =
        <StreamSubscription<Uint8List>>[];
    server.listen((Socket socket) {
      subscriptions.add(
        socket.listen((Uint8List data) {
          socket.add(data);
        }),
      );
    });
    return _EchoServer(server, subscriptions);
  }

  Future<void> stop() async {
    for (StreamSubscription<Uint8List> subscription in subscriptions) {
      await subscription.cancel();
    }
    await server.close();
  }
}

class _SocketReader {
  final StreamIterator<Uint8List> _iterator;
  Uint8List? _chunk;
  int _offset = 0;

  _SocketReader(Socket socket) : _iterator = StreamIterator<Uint8List>(socket);

  Future<List<int>> readExact(int length) async {
    List<int> result = <int>[];
    while (result.length < length) {
      result.add(await _readByte());
    }
    return result;
  }

  Future<int> _readByte() async {
    if (_chunk == null || _offset >= _chunk!.length) {
      bool moved = await _iterator.moveNext();
      if (!moved) {
        throw StateError('Socket closed');
      }
      _chunk = _iterator.current;
      _offset = 0;
    }
    int value = _chunk![_offset];
    _offset += 1;
    return value;
  }
}

void coreWeightedAddressSuite() {
  test('parses weighted addresses with default and explicit weight', () {
    RawWeightedAddress plain = RawWeightedAddress.parse('en0');
    RawWeightedAddress weighted = RawWeightedAddress.parse('10.0.0.5/3');

    expect(plain.target, 'en0');
    expect(plain.weight, 1);
    expect(weighted.target, '10.0.0.5');
    expect(weighted.weight, 3);
  });

  test('resolves interface names and literal IP addresses', () {
    List<NetworkInterfaceSnapshot> interfaces = <NetworkInterfaceSnapshot>[
      NetworkInterfaceSnapshot(
        name: 'en0',
        index: 1,
        addresses: <InternetAddress>[
          InternetAddress('10.0.0.4'),
          InternetAddress('fd00::4'),
        ],
      ),
    ];

    List<ResolvedWeightedAddress> resolved = const WeightedAddressResolver()
        .resolve(<RawWeightedAddress>[
          RawWeightedAddress.parse('en0/2'),
          RawWeightedAddress.parse('192.168.1.50'),
        ], interfaces);

    expect(resolved, hasLength(2));
    expect(resolved.first.label, 'en0');
    expect(resolved.first.weight, 2);
    expect(resolved.first.ipv4!.address, '10.0.0.4');
    expect(resolved.first.ipv6!.address, 'fd00::4');
    expect(resolved.last.ipv4!.address, '192.168.1.50');
  });

  test(
    'weighted round robin preserves weighted sequence per address family',
    () {
      WeightedRoundRobinDispatcher dispatcher =
          WeightedRoundRobinDispatcher(<ResolvedWeightedAddress>[
            ResolvedWeightedAddress(
              label: 'a',
              weight: 2,
              ipv4: InternetAddress('10.0.0.1'),
            ),
            ResolvedWeightedAddress(
              label: 'b',
              weight: 1,
              ipv4: InternetAddress('10.0.0.2'),
            ),
          ]);
      InternetAddress remote = InternetAddress('93.184.216.34');

      expect(dispatcher.dispatch(remote).address, '10.0.0.1');
      expect(dispatcher.dispatch(remote).address, '10.0.0.1');
      expect(dispatcher.dispatch(remote).address, '10.0.0.2');
      expect(dispatcher.dispatch(remote).address, '10.0.0.1');
    },
  );

  test('throws when remote address family has no local match', () {
    WeightedRoundRobinDispatcher dispatcher =
        WeightedRoundRobinDispatcher(<ResolvedWeightedAddress>[
          ResolvedWeightedAddress(
            label: 'v4',
            weight: 1,
            ipv4: InternetAddress('10.0.0.1'),
          ),
        ]);

    expect(
      () => dispatcher.dispatch(InternetAddress('fd00::10')),
      throwsA(isA<DispatchConfigException>()),
    );
  });
}

void main() {
  group('policy', corePolicySuite);
  group('socks proxy server', coreSocksProxyServerSuite);
  group('weighted address', coreWeightedAddressSuite);
}
