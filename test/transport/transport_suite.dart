import 'dart:async';
import 'dart:io';
import 'package:arcane_dispatch/bridge/tunnel_channel.dart';
import 'package:arcane_dispatch/core/bonding_mode.dart';
import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/network_interface_repository.dart';
import 'package:arcane_dispatch/core/policy.dart';
import 'package:arcane_dispatch/core/proxy_event.dart';
import 'package:arcane_dispatch/core/socks_proxy_server.dart';
import 'package:arcane_dispatch/core/weighted_address.dart';
import 'package:arcane_dispatch/policy/byte_accountant.dart';
import 'package:arcane_dispatch/transport/socks_transport.dart';
import 'package:arcane_dispatch/transport/transport.dart';
import 'package:arcane_dispatch/transport/tunnel_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void socksTransportSuite() {
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

    test(
      'start transitions stopped -> starting -> running and reports endpoint',
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
        StreamSubscription<TransportStatus> sub = transport.states.listen((
          TransportStatus s,
        ) {
          states.add(s.state);
        });

        Policy policy = Policy(
          links: <Link>[Link(id: 'l', label: 'l', interfaceName: 'en0')],
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
      },
    );

    test(
      'events emitted by inner server fan out through the transport',
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
        StreamSubscription<ProxyEvent> sub = transport.events.listen(seen.add);

        await transport.start(
          Policy(
            links: <Link>[Link(id: 'l', label: 'l', interfaceName: 'en0')],
          ),
        );

        // Replay an "info" event from the inner server.
        server.onEventSink!(
          ProxyEvent(type: ProxyEventType.info, message: 'hello'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(seen.any((ProxyEvent e) => e.message == 'hello'), isTrue);

        await sub.cancel();
        await transport.dispose();
      },
    );

    test('stop transitions running -> stopping -> stopped', () async {
      _FakeRepo repo = _FakeRepo();
      SocksTransport transport = SocksTransport(
        repository: repo,
        serverFactory: (ProxyEventSink onEvent, ByteAccountant _) =>
            _FakeServer(onEventSink: onEvent, boundPort: 1),
      );
      await transport.start(
        Policy(
          links: <Link>[Link(id: 'l', label: 'l', interfaceName: 'en0')],
        ),
      );
      List<TransportState> states = <TransportState>[];
      StreamSubscription<TransportStatus> sub = transport.states.listen(
        (TransportStatus s) => states.add(s.state),
      );

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

  _FakeServer({
    super.onEvent,
    ProxyEventSink? onEventSink,
    int? boundPort = 1080,
  }) : _boundPort = boundPort {
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

void tunnelTransportSuite() {
  // Tunnel transports never actually open the System Extension under test;
  // every interaction is routed through a [_FakeTunnelChannel] that lets the
  // test script the bridge's behavior and assert on the calls it made.

  Policy buildPolicy() {
    return Policy(
      mode: BondingMode.speed,
      links: <Link>[
        Link(
          id: 'en0',
          label: 'Wi-Fi',
          interfaceName: 'en0',
          weight: 1,
          priority: LinkPriority.primary,
        ),
      ],
    );
  }

  group('TunnelTransport.start', () {
    test(
      'pending extension approval surfaces a warning and fails the state',
      () async {
        _FakeTunnelChannel fake = _FakeTunnelChannel(
          installResult: TunnelInstallResult.pending(),
        );
        TunnelTransport transport = TunnelTransport(channel: fake);
        addTearDown(transport.dispose);

        List<ProxyEvent> events = <ProxyEvent>[];
        transport.events.listen(events.add);

        await transport.start(buildPolicy());

        expect(transport.status.state, TransportState.failed);
        expect(
          transport.status.errorMessage,
          contains('pending user approval'),
        );
        // We expect one info event ("Starting…") and one warning event
        // describing the pending state.
        await Future<void>.delayed(Duration.zero);
        expect(
          events.any((ProxyEvent e) => e.type == ProxyEventType.warning),
          isTrue,
        );
        // Critically, we should NOT have asked the bridge to start the VPN
        // since the extension isn't installed.
        expect(fake.startCalls, 0);
      },
    );

    test(
      'install failure surfaces an error string from the platform',
      () async {
        _FakeTunnelChannel fake = _FakeTunnelChannel(
          installResult: TunnelInstallResult.error('Permission denied'),
        );
        TunnelTransport transport = TunnelTransport(channel: fake);
        addTearDown(transport.dispose);

        await transport.start(buildPolicy());

        expect(transport.status.state, TransportState.failed);
        expect(transport.status.errorMessage, contains('Permission denied'));
        expect(fake.startCalls, 0);
      },
    );

    test(
      'TunnelUnavailableException reports a friendly fallback message',
      () async {
        _FakeTunnelChannel fake = _FakeTunnelChannel(
          installResult: TunnelInstallResult.ok(),
          installThrows: TunnelUnavailableException(),
        );
        TunnelTransport transport = TunnelTransport(channel: fake);
        addTearDown(transport.dispose);

        await transport.start(buildPolicy());

        expect(transport.status.state, TransportState.failed);
        expect(
          transport.status.errorMessage,
          contains('only available on macOS'),
        );
      },
    );

    test(
      'happy path schedules status polling and transitions to running',
      () async {
        _FakeTunnelChannel fake = _FakeTunnelChannel(
          installResult: TunnelInstallResult.ok(),
          statusQueue: <TunnelStatus>[
            // First poll: still starting.
            TunnelStatus(
              kind: TunnelStatusKind.starting,
              extensionBundleId: 'art.arcane.ArcaneDispatch.tunnel',
            ),
            // Second poll: connected.
            TunnelStatus(
              kind: TunnelStatusKind.connected,
              extensionBundleId: 'art.arcane.ArcaneDispatch.tunnel',
            ),
          ],
        );
        TunnelTransport transport = TunnelTransport(
          channel: fake,
          statusPollInterval: const Duration(milliseconds: 10),
        );
        addTearDown(transport.dispose);

        await transport.start(buildPolicy());

        // start() should have pushed the policy and asked the bridge to start.
        expect(fake.startCalls, 1);
        // The first immediate poll runs as a microtask after _scheduleStatusPolling.
        // Wait for at least two ticks to make sure we got to "connected".
        await _pumpUntil(
          () => transport.status.state == TransportState.running,
          timeout: const Duration(seconds: 1),
        );
        expect(transport.status.state, TransportState.running);
        expect(transport.status.endpoint, 'art.arcane.ArcaneDispatch.tunnel');
      },
    );
  });

  group('TunnelTransport.updatePolicy', () {
    test('uses writePolicy while stopped', () async {
      _FakeTunnelChannel fake = _FakeTunnelChannel(
        installResult: TunnelInstallResult.ok(),
      );
      TunnelTransport transport = TunnelTransport(channel: fake);
      addTearDown(transport.dispose);

      await transport.updatePolicy(buildPolicy());

      expect(fake.writePolicyCalls, 1);
      expect(fake.reloadPolicyCalls, 0);
    });

    test('uses reloadPolicy while running', () async {
      _FakeTunnelChannel fake = _FakeTunnelChannel(
        installResult: TunnelInstallResult.ok(),
        statusQueue: <TunnelStatus>[
          TunnelStatus(
            kind: TunnelStatusKind.connected,
            extensionBundleId: 'bundle',
          ),
        ],
      );
      TunnelTransport transport = TunnelTransport(
        channel: fake,
        statusPollInterval: const Duration(milliseconds: 5),
      );
      addTearDown(transport.dispose);

      await transport.start(buildPolicy());
      await _pumpUntil(
        () => transport.status.state == TransportState.running,
        timeout: const Duration(seconds: 1),
      );

      await transport.updatePolicy(buildPolicy());

      expect(fake.reloadPolicyCalls, 1);
      expect(fake.writePolicyCalls, 0);
    });
  });

  group('TunnelTransport.stop', () {
    test('cancels polling and transitions to stopped', () async {
      _FakeTunnelChannel fake = _FakeTunnelChannel(
        installResult: TunnelInstallResult.ok(),
        statusQueue: <TunnelStatus>[
          TunnelStatus(
            kind: TunnelStatusKind.connected,
            extensionBundleId: 'b',
          ),
        ],
      );
      TunnelTransport transport = TunnelTransport(
        channel: fake,
        statusPollInterval: const Duration(milliseconds: 5),
      );
      addTearDown(transport.dispose);

      await transport.start(buildPolicy());
      await _pumpUntil(
        () => transport.status.state == TransportState.running,
        timeout: const Duration(seconds: 1),
      );

      await transport.stop();

      expect(transport.status.state, TransportState.stopped);
      expect(fake.stopCalls, 1);
    });

    test('swallows TunnelUnavailableException', () async {
      _FakeTunnelChannel fake = _FakeTunnelChannel(
        installResult: TunnelInstallResult.ok(),
        stopThrows: TunnelUnavailableException(),
      );
      TunnelTransport transport = TunnelTransport(channel: fake);
      addTearDown(transport.dispose);

      // Should not throw.
      await transport.stop();
      expect(transport.status.state, TransportState.stopped);
    });
  });

  group('TunnelTransport.dispose', () {
    test('stops a running tunnel before closing streams', () async {
      _FakeTunnelChannel fake = _FakeTunnelChannel(
        installResult: TunnelInstallResult.ok(),
        statusQueue: <TunnelStatus>[
          TunnelStatus(
            kind: TunnelStatusKind.connected,
            extensionBundleId: 'b',
          ),
        ],
      );
      TunnelTransport transport = TunnelTransport(
        channel: fake,
        statusPollInterval: const Duration(milliseconds: 5),
      );

      await transport.start(buildPolicy());
      await _pumpUntil(
        () => transport.status.state == TransportState.running,
        timeout: const Duration(seconds: 1),
      );
      await transport.dispose();

      expect(fake.stopCalls, 1);
      expect(transport.status.state, TransportState.stopped);
    });

    test('is idempotent and closes all streams', () async {
      _FakeTunnelChannel fake = _FakeTunnelChannel(
        installResult: TunnelInstallResult.ok(),
      );
      TunnelTransport transport = TunnelTransport(channel: fake);

      await transport.dispose();
      // Second dispose is a no-op.
      await transport.dispose();

      expect(() => transport.start(buildPolicy()), throwsA(isA<StateError>()));
    });
  });
}

/// Pumps the event loop until [predicate] returns true or [timeout] elapses.
/// Avoids `await Future.delayed(...)` chains that flake under slow CI.
Future<void> _pumpUntil(
  bool Function() predicate, {
  required Duration timeout,
}) async {
  Stopwatch sw = Stopwatch()..start();
  while (!predicate() && sw.elapsed < timeout) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  if (!predicate()) {
    throw TimeoutException('Condition not met within $timeout');
  }
}

/// Scriptable fake — every public method on [TunnelChannel] is overridden so
/// the test can assert on call counts and inject responses.
class _FakeTunnelChannel implements TunnelChannel {
  final TunnelInstallResult installResult;
  final Object? installThrows;
  final Object? stopThrows;
  final List<TunnelStatus> statusQueue;

  int installCalls = 0;
  int startCalls = 0;
  int stopCalls = 0;
  int reloadPolicyCalls = 0;
  int writePolicyCalls = 0;
  int statusCalls = 0;

  _FakeTunnelChannel({
    required this.installResult,
    this.installThrows,
    this.stopThrows,
    List<TunnelStatus>? statusQueue,
  }) : statusQueue = statusQueue ?? <TunnelStatus>[];

  @override
  Future<TunnelInstallResult> installExtension() async {
    installCalls++;
    if (installThrows != null) {
      throw installThrows!;
    }
    return installResult;
  }

  @override
  Future<void> startTunnel({Policy? policy}) async {
    startCalls++;
  }

  @override
  Future<void> stopTunnel() async {
    stopCalls++;
    if (stopThrows != null) {
      throw stopThrows!;
    }
  }

  @override
  Future<void> reloadPolicy(Policy policy) async {
    reloadPolicyCalls++;
  }

  @override
  Future<bool> writePolicy(Policy policy) async {
    writePolicyCalls++;
    return true;
  }

  @override
  Future<TunnelStatus> status() async {
    statusCalls++;
    if (statusQueue.isEmpty) {
      return TunnelStatus.unknown();
    }
    // Pop from the front; once exhausted, repeat the last one so polling
    // doesn't get stuck on "unknown".
    if (statusQueue.length == 1) {
      return statusQueue.first;
    }
    return statusQueue.removeAt(0);
  }

  @override
  Future<List<TunnelThroughputSample>> getThroughput() async {
    // No bonded forwarder running in tests — return an empty list so
    // TunnelTransport's polling loop is a no-op.
    return const <TunnelThroughputSample>[];
  }

  // The relay config methods aren't exercised by the tunnel transport
  // itself, but the fake has to implement the interface or the
  // analyzer trips. Hand them in-memory storage so dedicated tests in
  // `test/bridge/tunnel_channel_test.dart` can drive them via the real
  // channel.
  String _fakeServerEndpoint = '';
  String _fakeServerToken = '';

  @override
  Future<bool> setServer({
    required String endpoint,
    required String token,
  }) async {
    _fakeServerEndpoint = endpoint;
    _fakeServerToken = token;
    return true;
  }

  @override
  Future<TunnelServerConfig> getServer() async {
    return TunnelServerConfig(
      endpoint: _fakeServerEndpoint,
      tokenSet: _fakeServerToken.isNotEmpty,
    );
  }

  // Keychain bridge stubs (Phase 9.11). The transport doesn't drive these
  // directly — the controller does — but the fake still has to satisfy
  // the interface. Dedicated coverage lives in
  // `test/bridge/tunnel_channel_test.dart`.
  final String _fakeClientPublicKey = '';
  String _capturedResponderKey = '';

  @override
  Future<String?> getClientPublicKey() async {
    return _fakeClientPublicKey.isEmpty ? null : _fakeClientPublicKey;
  }

  @override
  Future<bool> setResponderPublicKey(String publicKeyBase64) async {
    _capturedResponderKey = publicKeyBase64;
    return true;
  }

  /// Diagnostic accessor so tests adding responder-key coverage can read
  /// back what the transport pushed without exposing the field directly.
  String get lastResponderKey => _capturedResponderKey;
}

void main() {
  group('socks transport', socksTransportSuite);
  group('tunnel transport', tunnelTransportSuite);
}
