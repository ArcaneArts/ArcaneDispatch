// Phase 11 protocol-ladder tests. Lock the fallback ordering, the
// timeout behavior, and the diagnostic surface that the UI / metric
// stream consumes via [LadderResult.toDecision].

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/protocol/protocol_ladder.dart';

/// Test transport that records what was sent and never blocks. The
/// ladder itself doesn't care about send semantics — only `negotiate`
/// is exercised — but this lets us assert that [LadderResult.chosen]
/// carries a *working* transport rather than null on success.
class _FakeTransport implements LinkProtocolTransport {
  @override
  final LinkProtocol protocol;
  final StreamController<Uint8List> _inbound =
      StreamController<Uint8List>.broadcast();
  bool _closed = false;
  List<Uint8List> sent = <Uint8List>[];

  _FakeTransport(this.protocol);

  @override
  bool get isClosed => _closed;

  @override
  bool send(Uint8List bytes) {
    if (_closed) return false;
    sent.add(bytes);
    return true;
  }

  @override
  Stream<Uint8List> get inbound => _inbound.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _inbound.close();
  }
}

void main() {
  group('LinkProtocolCodec', () {
    test('round-trips every variant via wireName <-> parse', () {
      for (LinkProtocol p in LinkProtocol.values) {
        expect(LinkProtocolCodec.parse(p.wireName), p);
      }
    });

    test('unknown string falls back to UDP', () {
      expect(LinkProtocolCodec.parse('flooper'), LinkProtocol.udp443);
    });
  });

  group('ProtocolLadder.negotiate', () {
    test('returns the first rung on the happy path', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) => () async => ProbeResult(
              protocol: p,
              transport: _FakeTransport(p),
              elapsed: const Duration(milliseconds: 10),
            ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.chosen?.protocol, LinkProtocol.udp443);
      expect(result.attempts, hasLength(1),
          reason: 'No fallback rungs should be attempted on first success');
      expect(result.toDecision().rejected, isEmpty);
    });

    test('falls back to TCP when UDP fails', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) => () async {
          if (p == LinkProtocol.udp443) {
            return ProbeResult.failed(
              protocol: p,
              reason: 'connection refused',
              elapsed: const Duration(milliseconds: 5),
            );
          }
          return ProbeResult(
            protocol: p,
            transport: _FakeTransport(p),
            elapsed: const Duration(milliseconds: 20),
          );
        },
      );

      expect(result.isSuccess, isTrue);
      expect(result.chosen?.protocol, LinkProtocol.tcp443);
      expect(result.attempts.map((ProbeResult r) => r.protocol),
          <LinkProtocol>[LinkProtocol.udp443, LinkProtocol.tcp443]);
      expect(result.toDecision().rejected, <LinkProtocol>[LinkProtocol.udp443]);
    });

    test('falls all the way through UDP → TCP → TLS', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) => () async {
          if (p != LinkProtocol.tls443) {
            return ProbeResult.failed(
              protocol: p,
              reason: 'middle-box blocked',
              elapsed: const Duration(milliseconds: 5),
            );
          }
          return ProbeResult(
            protocol: p,
            transport: _FakeTransport(p),
            elapsed: const Duration(milliseconds: 40),
          );
        },
      );

      expect(result.isSuccess, isTrue);
      expect(result.chosen?.protocol, LinkProtocol.tls443);
      expect(result.toDecision().rejected, <LinkProtocol>[
        LinkProtocol.udp443,
        LinkProtocol.tcp443,
      ]);
    });

    test('returns failure when every rung fails', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) => () async => ProbeResult.failed(
              protocol: p,
              reason: 'no route',
              elapsed: const Duration(milliseconds: 5),
            ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.chosen, isNull);
      expect(result.attempts, hasLength(3));
      expect(result.attempts.every((ProbeResult r) => !r.isSuccess), isTrue);
    });

    test('respects perStepTimeout when a probe never returns', () async {
      // Make every step hang. Timeout MUST kick in on each rung; total
      // elapsed should be roughly N * perStepTimeout.
      ProtocolLadder ladder = const ProtocolLadder(
        perStepTimeout: Duration(milliseconds: 30),
      );

      Future<ProbeResult> hang(LinkProtocol p) {
        Completer<ProbeResult> c = Completer<ProbeResult>();
        // Never completes.
        return c.future;
      }

      LadderResult result =
          await ladder.negotiate((LinkProtocol p) => () => hang(p));

      expect(result.isSuccess, isFalse);
      expect(result.attempts, hasLength(3));
      expect(
        result.attempts.every((ProbeResult r) => r.failureReason!.contains('timed out')),
        isTrue,
      );
      // Should be roughly 3 * 30 ms; allow generous slack for CI.
      expect(result.totalElapsed.inMilliseconds, greaterThanOrEqualTo(85));
      expect(result.totalElapsed.inMilliseconds, lessThanOrEqualTo(800));
    });

    test('respects a custom ordering', () async {
      ProtocolLadder ladder = const ProtocolLadder(
        ordering: <LinkProtocol>[
          LinkProtocol.tls443,
          LinkProtocol.udp443,
        ],
      );

      List<LinkProtocol> attempted = <LinkProtocol>[];
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) => () async {
          attempted.add(p);
          if (p == LinkProtocol.tls443) {
            return ProbeResult.failed(
              protocol: p,
              reason: 'dpi blocked',
              elapsed: const Duration(milliseconds: 5),
            );
          }
          return ProbeResult(
            protocol: p,
            transport: _FakeTransport(p),
            elapsed: const Duration(milliseconds: 10),
          );
        },
      );

      expect(attempted,
          <LinkProtocol>[LinkProtocol.tls443, LinkProtocol.udp443]);
      expect(result.chosen?.protocol, LinkProtocol.udp443);
    });

    test('converts a thrown error into a failure result', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      LadderResult result = await ladder.negotiate(
        (LinkProtocol p) => () async {
          if (p == LinkProtocol.udp443) {
            throw const FormatException('handshake garbled');
          }
          return ProbeResult(
            protocol: p,
            transport: _FakeTransport(p),
            elapsed: const Duration(milliseconds: 10),
          );
        },
      );

      expect(result.attempts.first.isSuccess, isFalse);
      expect(result.attempts.first.failureReason, contains('handshake garbled'));
      expect(result.chosen?.protocol, LinkProtocol.tcp443);
    });
  });

  group('ProtocolLadder.tryStep', () {
    test('returns the probe outcome verbatim on success', () async {
      ProtocolLadder ladder = const ProtocolLadder();
      ProbeResult r = await ladder.tryStep(
        LinkProtocol.udp443,
        () async => ProbeResult(
          protocol: LinkProtocol.udp443,
          transport: _FakeTransport(LinkProtocol.udp443),
          elapsed: const Duration(milliseconds: 1),
        ),
      );
      expect(r.isSuccess, isTrue);
      expect(r.protocol, LinkProtocol.udp443);
    });

    test('respects perStepTimeout for a single-step run', () async {
      ProtocolLadder ladder = const ProtocolLadder(
        perStepTimeout: Duration(milliseconds: 25),
      );
      ProbeResult r = await ladder.tryStep(
        LinkProtocol.udp443,
        () => Completer<ProbeResult>().future, // never completes
      );
      expect(r.isSuccess, isFalse);
      expect(r.failureReason, contains('timed out'));
    });
  });

  group('LadderResult.toDecision', () {
    test('returns a usable decision even when nothing succeeded', () {
      LadderResult result = LadderResult(
        chosen: null,
        attempts: <ProbeResult>[
          ProbeResult.failed(
            protocol: LinkProtocol.udp443,
            reason: 'x',
            elapsed: const Duration(milliseconds: 1),
          ),
          ProbeResult.failed(
            protocol: LinkProtocol.tcp443,
            reason: 'y',
            elapsed: const Duration(milliseconds: 1),
          ),
        ],
        totalElapsed: const Duration(milliseconds: 2),
      );
      LinkProtocolDecision d = result.toDecision();
      // Falls back to the last-attempted rung so the UI shows
      // something meaningful instead of a bogus "we chose UDP" message.
      expect(d.chosen, LinkProtocol.tcp443);
      expect(d.rejected, <LinkProtocol>[
        LinkProtocol.udp443,
        LinkProtocol.tcp443,
      ]);
    });
  });
}
