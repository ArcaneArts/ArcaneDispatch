import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/bridge/tunnel_channel.dart';
import 'package:arcane_dispatch/core/bonding_mode.dart';
import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/policy.dart';
import 'package:arcane_dispatch/core/proxy_event.dart';
import 'package:arcane_dispatch/transport/transport.dart';
import 'package:arcane_dispatch/transport/tunnel_transport.dart';

void main() {
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
    test('pending extension approval surfaces a warning and fails the state',
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
      expect(transport.status.errorMessage, contains('pending user approval'));
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
    });

    test('install failure surfaces an error string from the platform',
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
    });

    test('TunnelUnavailableException reports a friendly fallback message',
        () async {
      _FakeTunnelChannel fake = _FakeTunnelChannel(
        installResult: TunnelInstallResult.ok(),
        installThrows: TunnelUnavailableException(),
      );
      TunnelTransport transport = TunnelTransport(channel: fake);
      addTearDown(transport.dispose);

      await transport.start(buildPolicy());

      expect(transport.status.state, TransportState.failed);
      expect(transport.status.errorMessage, contains('only available on macOS'));
    });

    test('happy path schedules status polling and transitions to running',
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
    });
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
          TunnelStatus(kind: TunnelStatusKind.connected, extensionBundleId: 'b'),
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
    test('is idempotent and closes all streams', () async {
      _FakeTunnelChannel fake = _FakeTunnelChannel(
        installResult: TunnelInstallResult.ok(),
      );
      TunnelTransport transport = TunnelTransport(channel: fake);

      await transport.dispose();
      // Second dispose is a no-op.
      await transport.dispose();

      expect(
        () => transport.start(buildPolicy()),
        throwsA(isA<StateError>()),
      );
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
  Future<String?> flowStatsPath() async {
    // No flow stats in unit-test context — the reader will sit idle.
    return null;
  }

  // The Speed Server config methods aren't exercised by the tunnel
  // transport itself yet (they're driven directly from the controller in
  // Phase 8.12), but the fake has to implement the interface or the
  // analyzer trips. Hand them in-memory storage so dedicated tests in
  // `test/bridge/tunnel_channel_test.dart` can drive them via the real
  // channel.
  String _fakeServerEndpoint = '';
  String _fakeServerToken = '';

  @override
  Future<bool> setServer({required String endpoint, required String token}) async {
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
