import 'dart:async';
import 'dart:io';

import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/network_interface_repository.dart';
import 'package:arcane_dispatch/core/policy.dart';
import 'package:arcane_dispatch/core/proxy_event.dart';
import 'package:arcane_dispatch/core/socks_proxy_server.dart';
import 'package:arcane_dispatch/core/weighted_address.dart';
import 'package:arcane_dispatch/policy/byte_accountant.dart';
import 'package:arcane_dispatch/transport/socks_transport.dart';
import 'package:arcane_dispatch/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SocksTransport', () {
    test('reports SOCKS kind and stopped initial status', () async {
      _FakeRepo repo = _FakeRepo();
      SocksTransport transport = SocksTransport(
        repository: repo,
        serverFactory: (ProxyEventSink onEvent, ByteAccountant _) =>
            _FakeServer(onEvent: onEvent),
      );

      expect(transport.kind, TransportKind.socks);
      expect(transport.status.state, TransportState.stopped);
      expect(transport.status.isRunning, isFalse);
      await transport.dispose();
    });

    test('refuses to start when policy has no eligible links', () async {
      _FakeRepo repo = _FakeRepo();
      SocksTransport transport = SocksTransport(
        repository: repo,
        serverFactory: (ProxyEventSink onEvent, ByteAccountant _) =>
            _FakeServer(onEvent: onEvent),
      );
      Policy policy = Policy(
        links: <Link>[
          Link(
            id: 'l',
            label: 'l',
            interfaceName: 'en0',
            priority: LinkPriority.never,
          ),
        ],
      );

      await expectLater(
        transport.start(policy),
        throwsA(isA<DispatchConfigException>()),
      );
      expect(transport.status.state, TransportState.failed);
      expect(transport.status.errorMessage, contains('Select at least one'));
      await transport.dispose();
    });

    test('start transitions stopped -> starting -> running and reports endpoint',
        () async {
      _FakeRepo repo = _FakeRepo();
      _FakeServer server = _FakeServer(boundPort: 4242);
      SocksTransport transport = SocksTransport(
        repository: repo,
        serverFactory: (ProxyEventSink onEvent, ByteAccountant _) {
          server.onEventSink = onEvent;
          return server;
        },
        config: const SocksTransportConfig(
          listenHost: '127.0.0.1',
          listenPort: 0,
        ),
      );

      List<TransportState> states = <TransportState>[];
      StreamSubscription<TransportStatus> sub =
          transport.states.listen((TransportStatus s) {
        states.add(s.state);
      });

      Policy policy = Policy(
        links: <Link>[
          Link(id: 'l', label: 'l', interfaceName: 'en0'),
        ],
      );
      await transport.start(policy);
      await Future<void>.delayed(Duration.zero);

      expect(server.started, isTrue);
      expect(transport.status.state, TransportState.running);
      expect(transport.status.endpoint, '127.0.0.1:4242');
      expect(states, contains(TransportState.starting));
      expect(states.last, TransportState.running);

      await sub.cancel();
      await transport.dispose();
    });

    test('events emitted by inner server fan out through the transport',
        () async {
      _FakeRepo repo = _FakeRepo();
      late _FakeServer server;
      SocksTransport transport = SocksTransport(
        repository: repo,
        serverFactory: (ProxyEventSink onEvent, ByteAccountant _) {
          server = _FakeServer(onEventSink: onEvent);
          return server;
        },
      );

      List<ProxyEvent> seen = <ProxyEvent>[];
      StreamSubscription<ProxyEvent> sub =
          transport.events.listen(seen.add);

      await transport.start(
        Policy(links: <Link>[Link(id: 'l', label: 'l', interfaceName: 'en0')]),
      );

      // Replay an "info" event from the inner server.
      server.onEventSink!(
        ProxyEvent(type: ProxyEventType.info, message: 'hello'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(seen.any((ProxyEvent e) => e.message == 'hello'), isTrue);

      await sub.cancel();
      await transport.dispose();
    });

    test('flows stream emits open + close pairs', () async {
      _FakeRepo repo = _FakeRepo();
      late _FakeServer server;
      SocksTransport transport = SocksTransport(
        repository: repo,
        serverFactory: (ProxyEventSink onEvent, ByteAccountant _) {
          server = _FakeServer(onEventSink: onEvent);
          return server;
        },
      );

      List<DateTime> openedAts = <DateTime>[];
      List<DateTime?> closedAts = <DateTime?>[];
      StreamSubscription sub = transport.flows.listen((flow) {
        openedAts.add(flow.openedAt);
        closedAts.add(flow.closedAt);
      });

      await transport.start(
        Policy(links: <Link>[Link(id: 'l', label: 'l', interfaceName: 'en0')]),
      );

      DateTime t = DateTime.utc(2026, 5, 11, 12);
      ProxyEvent openEvent = ProxyEvent(
        type: ProxyEventType.connectionOpened,
        message: 'open',
        remoteAddress: InternetAddress('1.2.3.4'),
        remotePort: 443,
        localAddress: InternetAddress('10.0.0.4'),
        timestamp: t,
      );
      ProxyEvent closeEvent = ProxyEvent(
        type: ProxyEventType.connectionClosed,
        message: 'close',
        remoteAddress: InternetAddress('1.2.3.4'),
        remotePort: 443,
        localAddress: InternetAddress('10.0.0.4'),
        timestamp: t,
      );
      server.onEventSink!(openEvent);
      server.onEventSink!(closeEvent);
      await Future<void>.delayed(Duration.zero);

      // One open (closedAt=null) and one closed (closedAt!=null).
      expect(closedAts.contains(null), isTrue);
      expect(closedAts.any((DateTime? v) => v != null), isTrue);

      await sub.cancel();
      await transport.dispose();
    });

    test('stop transitions running -> stopping -> stopped', () async {
      _FakeRepo repo = _FakeRepo();
      SocksTransport transport = SocksTransport(
        repository: repo,
        serverFactory: (ProxyEventSink onEvent, ByteAccountant _) => _FakeServer(
          onEventSink: onEvent,
          boundPort: 1,
        ),
      );
      await transport.start(
        Policy(links: <Link>[Link(id: 'l', label: 'l', interfaceName: 'en0')]),
      );
      List<TransportState> states = <TransportState>[];
      StreamSubscription<TransportStatus> sub =
          transport.states.listen((TransportStatus s) => states.add(s.state));

      await transport.stop();
      await Future<void>.delayed(Duration.zero);
      expect(transport.status.state, TransportState.stopped);
      expect(states, contains(TransportState.stopping));
      expect(states.last, TransportState.stopped);

      await sub.cancel();
      await transport.dispose();
    });

    test('updatePolicy restarts when running', () async {
      _FakeRepo repo = _FakeRepo();
      List<_FakeServer> built = <_FakeServer>[];
      SocksTransport transport = SocksTransport(
        repository: repo,
        serverFactory: (ProxyEventSink onEvent, ByteAccountant _) {
          _FakeServer s = _FakeServer(onEventSink: onEvent, boundPort: 1);
          built.add(s);
          return s;
        },
      );
      Policy first = Policy(
        links: <Link>[Link(id: 'l', label: 'l', interfaceName: 'en0')],
      );
      await transport.start(first);
      Policy second = Policy(
        links: <Link>[Link(id: 'l2', label: 'l2', interfaceName: 'en1')],
      );

      await transport.updatePolicy(second);
      expect(transport.status.state, TransportState.running);
      // The inner server was reused (single instance) but start was called twice.
      expect(built.first.startCalls, 2);
      expect(built.first.lastAddresses.length, 1);

      await transport.dispose();
    });

    test('dispose is idempotent', () async {
      _FakeRepo repo = _FakeRepo();
      SocksTransport transport = SocksTransport(
        repository: repo,
        serverFactory: (ProxyEventSink onEvent, ByteAccountant _) =>
            _FakeServer(onEvent: onEvent),
      );
      await transport.dispose();
      await transport.dispose(); // second call should be a no-op
    });
  });
}

class _FakeRepo extends NetworkInterfaceRepository {
  const _FakeRepo();

  @override
  Future<List<NetworkInterfaceSnapshot>> listUsableInterfaces() async {
    return <NetworkInterfaceSnapshot>[
      NetworkInterfaceSnapshot(
        name: 'en0',
        index: 1,
        addresses: <InternetAddress>[InternetAddress('10.0.0.4')],
      ),
      NetworkInterfaceSnapshot(
        name: 'en1',
        index: 2,
        addresses: <InternetAddress>[InternetAddress('10.0.0.5')],
      ),
    ];
  }
}

class _FakeServer extends SocksProxyServer {
  bool started = false;
  int startCalls = 0;
  int stopCalls = 0;
  final int? _boundPort;
  List<ResolvedWeightedAddress> lastAddresses = <ResolvedWeightedAddress>[];
  ProxyEventSink? onEventSink;

  _FakeServer({super.onEvent, ProxyEventSink? onEventSink, int? boundPort = 1080})
      : _boundPort = boundPort {
    this.onEventSink = onEventSink ?? onEvent;
  }

  @override
  bool get isRunning => started;

  @override
  int? get boundPort => _boundPort;

  @override
  Future<void> start({
    required InternetAddress listenAddress,
    required int port,
    required List<ResolvedWeightedAddress> addresses,
  }) async {
    started = true;
    startCalls += 1;
    lastAddresses = addresses;
  }

  @override
  Future<void> stop() async {
    started = false;
    stopCalls += 1;
  }
}
