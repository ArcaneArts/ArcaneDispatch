// Tests for `lib/protocol/link_negotiation_loop.dart`.
//
// We mock the `LadderRunner` to make these tests hermetic. The real
// runner does live socket I/O which is covered by the integration
// tests under `speed-server/`.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/core/link_metric.dart';
import 'package:arcane_dispatch/protocol/link_negotiation_loop.dart';
import 'package:arcane_dispatch/protocol/protocol_ladder.dart';

void main() {
  group('LinkNegotiationLoop', () {
    test('bootstrap runs the ladder once and emits the change', () async {
      final changes = <(String, LinkProtocol)>[];
      final loop = LinkNegotiationLoop(
        runner: (linkId) async => _success(LinkProtocol.udp443, 5),
        onProtocolChange: (id, r) => changes.add((id, r.chosen!.protocol)),
      );

      final link = _link('wifi');
      final r = await loop.bootstrap(link);
      expect(r?.isSuccess, isTrue);
      expect(r?.chosen?.protocol, LinkProtocol.udp443);
      expect(changes, [('wifi', LinkProtocol.udp443)]);

      // Second bootstrap is a no-op (same protocol, no new event).
      await loop.bootstrap(link);
      expect(changes.length, 1);
    });

    test('healthy metrics do not trigger a re-negotiation', () async {
      var runs = 0;
      final loop = LinkNegotiationLoop(
        runner: (linkId) async {
          runs += 1;
          return _success(LinkProtocol.udp443, 5);
        },
        onProtocolChange: (id, result) {},
      );
      await loop.bootstrap(_link('wifi'));
      runs = 0;

      for (var i = 0; i < 10; i++) {
        await loop.onMetric('wifi', _metric('wifi', loss: 0.0));
      }
      expect(runs, 0);
    });

    test('lossy streak hits threshold triggers re-negotiation', () async {
      var runs = 0;
      var nextProtocol = LinkProtocol.udp443;
      final changes = <LinkProtocol>[];
      final loop = LinkNegotiationLoop(
        runner: (linkId) async {
          runs += 1;
          return _success(nextProtocol, 1);
        },
        onProtocolChange: (_, r) => changes.add(r.chosen!.protocol),
        config: const LinkNegotiationLoopConfig(
          lossThreshold: 0.05,
          consecutiveSamples: 3,
          cooldown: Duration.zero,
        ),
      );

      await loop.bootstrap(_link('wifi'));
      runs = 0;
      changes.clear();

      // Two lossy samples don't fire yet.
      await loop.onMetric('wifi', _metric('wifi', loss: 0.10));
      await loop.onMetric('wifi', _metric('wifi', loss: 0.20));
      expect(runs, 0);

      // Flip the next protocol so we can observe the change event.
      nextProtocol = LinkProtocol.tcp443;
      await loop.onMetric('wifi', _metric('wifi', loss: 0.15));
      expect(runs, 1);
      expect(changes, [LinkProtocol.tcp443]);
    });

    test('a healthy sample resets the lossy streak', () async {
      var runs = 0;
      final loop = LinkNegotiationLoop(
        runner: (linkId) async {
          runs += 1;
          return _success(LinkProtocol.udp443, 1);
        },
        onProtocolChange: (id, result) {},
        config: const LinkNegotiationLoopConfig(
          lossThreshold: 0.05,
          consecutiveSamples: 3,
          cooldown: Duration.zero,
        ),
      );
      await loop.bootstrap(_link('wifi'));
      runs = 0;

      await loop.onMetric('wifi', _metric('wifi', loss: 0.10));
      await loop.onMetric('wifi', _metric('wifi', loss: 0.10));
      await loop.onMetric('wifi', _metric('wifi', loss: 0.00)); // reset
      await loop.onMetric('wifi', _metric('wifi', loss: 0.10));
      await loop.onMetric('wifi', _metric('wifi', loss: 0.10));
      expect(runs, 0, reason: 'reset should have cleared the streak');
    });

    test('cooldown suppresses back-to-back re-negotiations', () async {
      var runs = 0;
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final loop = LinkNegotiationLoop(
        runner: (linkId) async {
          runs += 1;
          return _success(LinkProtocol.udp443, 1);
        },
        onProtocolChange: (id, result) {},
        now: () => now,
        config: const LinkNegotiationLoopConfig(
          lossThreshold: 0.05,
          consecutiveSamples: 1,
          cooldown: Duration(seconds: 30),
        ),
      );
      await loop.bootstrap(_link('wifi'));
      runs = 0;
      // Advance past the cooldown so the bootstrap's `lastNegotiateAt`
      // doesn't suppress our first lossy metric.
      now = now.add(const Duration(seconds: 31));

      // First lossy hit triggers a re-negotiate.
      await loop.onMetric('wifi', _metric('wifi', loss: 0.20));
      expect(runs, 1);

      // 10 s later, still within cooldown — no fire.
      now = now.add(const Duration(seconds: 10));
      await loop.onMetric('wifi', _metric('wifi', loss: 0.20));
      expect(runs, 1);

      // 31 s later, cooldown elapsed — fires again.
      now = now.add(const Duration(seconds: 22));
      await loop.onMetric('wifi', _metric('wifi', loss: 0.20));
      expect(runs, 2);
    });

    test('runner timeout returns a failed result without crashing',
        () async {
      final loop = LinkNegotiationLoop(
        runner: (linkId) {
          final completer = Completer<LadderResult>();
          // Never completes — should hit the budget timeout.
          return completer.future;
        },
        onProtocolChange: (id, result) {
          fail('no change should be emitted on a budget timeout');
        },
        config: const LinkNegotiationLoopConfig(
          negotiateBudget: Duration(milliseconds: 50),
          lossThreshold: 0.05,
          consecutiveSamples: 1,
          cooldown: Duration.zero,
        ),
      );
      final r = await loop.bootstrap(_link('wifi'));
      expect(r?.isSuccess, isFalse);
    });

    test('forget removes per-link state', () async {
      final loop = LinkNegotiationLoop(
        runner: (linkId) async => _success(LinkProtocol.udp443, 1),
        onProtocolChange: (id, result) {},
      );
      await loop.bootstrap(_link('wifi'));
      expect(loop.snapshot().containsKey('wifi'), isTrue);
      loop.forget('wifi');
      expect(loop.snapshot().containsKey('wifi'), isFalse);
    });

    test('forceNegotiate runs the ladder regardless of metrics', () async {
      var runs = 0;
      final loop = LinkNegotiationLoop(
        runner: (linkId) async {
          runs += 1;
          return _success(LinkProtocol.udp443, 1);
        },
        onProtocolChange: (id, result) {},
      );
      await loop.forceNegotiate('wifi');
      expect(runs, 1);
      await loop.forceNegotiate('wifi');
      expect(runs, 2);
    });
  });
}

LadderResult _success(LinkProtocol p, int attemptCount) {
  return LadderResult(
    chosen: ProbeResult(
      protocol: p,
      elapsed: const Duration(milliseconds: 10),
      transport: _StubTransport(p),
    ),
    attempts: List.generate(
      attemptCount,
      (i) => ProbeResult(
        protocol: p,
        elapsed: const Duration(milliseconds: 5),
        transport: i == attemptCount - 1 ? _StubTransport(p) : null,
        failureReason: i == attemptCount - 1 ? null : 'simulated',
      ),
    ),
    totalElapsed: const Duration(milliseconds: 15),
  );
}

Link _link(String id) {
  return Link(
    id: id,
    label: id,
    interfaceName: id,
    sourceAddress: '10.0.0.1',
    weight: 1,
    priority: LinkPriority.primary,
  );
}

LinkMetric _metric(String linkId, {required double loss}) {
  return LinkMetric(
    linkId: linkId,
    capturedAt: DateTime.now(),
    loss: loss,
  );
}

class _StubTransport implements LinkProtocolTransport {
  @override
  final LinkProtocol protocol;
  @override
  bool isClosed = false;
  @override
  Stream<Uint8List> get inbound => const Stream<Uint8List>.empty();

  _StubTransport(this.protocol);

  @override
  Future<void> close() async => isClosed = true;

  @override
  bool send(Uint8List bytes) => !isClosed;
}
