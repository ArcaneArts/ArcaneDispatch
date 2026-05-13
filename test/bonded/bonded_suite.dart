import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:arcane_dispatch/bonded/bonded_framing.dart';
import 'package:arcane_dispatch/bonded/bonded_modes.dart';
import 'package:arcane_dispatch/bonded/bonded_reassembler.dart';
import 'package:arcane_dispatch/bonded/bonded_scheduler.dart';
import 'package:arcane_dispatch/bonded/local_bonded_loopback.dart';
import 'package:arcane_dispatch/core/bonding_mode.dart';
import 'package:arcane_dispatch/core/link.dart';
import 'package:flutter_test/flutter_test.dart';

// Wire-format round-trip + edge-case coverage for the bonded protocol v0.
//
// These tests are the spec contract for both `bonded_framing.dart` and its
// Swift mirror at `macos/ArcaneDispatchTunnel/Bonded/BondedFraming.swift`. If
// you change a byte offset, change them both and update this file.

void bondedFramingSuite() {
  group('encodeBondedFrame', () {
    test('emits a 24-byte header for an empty payload', () {
      Uint8List bytes = encodeBondedFrame(sessionId: 0, seq: 0, linkId: 0);
      expect(bytes.length, kBondedHeaderSize);
      // magic = 0xDA01 big-endian
      expect(bytes[0], 0xDA);
      expect(bytes[1], 0x01);
      // version = 1
      expect(bytes[2], 1);
      // flags = 0
      expect(bytes[3], 0);
    });

    test('writes fields big-endian at the documented offsets', () {
      Uint8List payload = Uint8List.fromList(<int>[0xDE, 0xAD, 0xBE, 0xEF]);
      Uint8List bytes = encodeBondedFrame(
        sessionId: 0x1122334455667788,
        seq: 0x0102030405060708,
        linkId: 0xCAFE,
        flags: BondedFlags.ack | BondedFlags.retransmit,
        payload: payload,
      );
      expect(bytes.length, kBondedHeaderSize + payload.length);
      ByteData bd = ByteData.sublistView(bytes);
      expect(bd.getUint16(0, Endian.big), kBondedMagic);
      expect(bytes[2], kBondedProtocolVersion);
      expect(bytes[3], BondedFlags.ack | BondedFlags.retransmit);
      expect(bd.getUint64(4, Endian.big), 0x1122334455667788);
      expect(bd.getUint64(12, Endian.big), 0x0102030405060708);
      expect(bd.getUint16(20, Endian.big), 0xCAFE);
      expect(bd.getUint16(22, Endian.big), payload.length);
      expect(bytes.sublist(kBondedHeaderSize), payload);
    });

    test('rejects payload larger than the wire cap', () {
      Uint8List big = Uint8List(kBondedMaxPayload + 1);
      expect(
        () => encodeBondedFrame(sessionId: 1, seq: 0, linkId: 0, payload: big),
        throwsA(isA<BondedFramingException>()),
      );
    });

    test('rejects reserved flag bits', () {
      expect(
        () => encodeBondedFrame(
          sessionId: 1,
          seq: 0,
          linkId: 0,
          flags: 0x80, // reserved bit 7
        ),
        throwsA(isA<BondedFramingException>()),
      );
    });

    test('rejects linkId outside u16 range', () {
      expect(
        () => encodeBondedFrame(sessionId: 1, seq: 0, linkId: 0x1_0000),
        throwsA(isA<BondedFramingException>()),
      );
    });

    test('round-trips a sessionId with the high bit set (u64 wraparound)', () {
      // Dart `int` is signed 64-bit, so this literal looks negative. The
      // framing layer must treat it as the unsigned bit pattern.
      int sessionId = 0xABCD000000000001;
      Uint8List bytes = encodeBondedFrame(
        sessionId: sessionId,
        seq: 0,
        linkId: 0,
      );
      BondedFrame frame = decodeBondedFrame(bytes);
      expect(frame.sessionId, sessionId);
    });

    test('accepts the payload at exactly the wire cap', () {
      Uint8List body = Uint8List(kBondedMaxPayload);
      for (int i = 0; i < body.length; i++) {
        body[i] = i & 0xff;
      }
      Uint8List bytes = encodeBondedFrame(
        sessionId: 7,
        seq: 100,
        linkId: 2,
        payload: body,
      );
      expect(bytes.length, kBondedHeaderSize + kBondedMaxPayload);
    });
  });

  group('decodeBondedFrame', () {
    test('round-trips a non-trivial frame', () {
      Uint8List payload = Uint8List.fromList(
        List<int>.generate(64, (int i) => (i * 7) & 0xff),
      );
      Uint8List bytes = encodeBondedFrame(
        sessionId: 9999,
        seq: 123456789,
        linkId: 3,
        flags: BondedFlags.retransmit,
        payload: payload,
      );
      BondedFrame frame = decodeBondedFrame(bytes);
      expect(frame.magic, kBondedMagic);
      expect(frame.version, kBondedProtocolVersion);
      expect(frame.flags, BondedFlags.retransmit);
      expect(frame.isRetransmit, isTrue);
      expect(frame.isAck, isFalse);
      expect(frame.sessionId, 9999);
      expect(frame.seq, 123456789);
      expect(frame.linkId, 3);
      expect(frame.payload, payload);
    });

    test('rejects a header that is too short', () {
      Uint8List bytes = Uint8List(kBondedHeaderSize - 1);
      expect(
        () => decodeBondedFrame(bytes),
        throwsA(isA<BondedFramingException>()),
      );
    });

    test('rejects a frame with the wrong magic', () {
      Uint8List bytes = encodeBondedFrame(sessionId: 1, seq: 0, linkId: 0);
      bytes[0] = 0x00;
      bytes[1] = 0x00;
      expect(
        () => decodeBondedFrame(bytes),
        throwsA(isA<BondedFramingException>()),
      );
    });

    test('rejects a frame with a future protocol version', () {
      Uint8List bytes = encodeBondedFrame(sessionId: 1, seq: 0, linkId: 0);
      bytes[2] = kBondedProtocolVersion + 1;
      expect(
        () => decodeBondedFrame(bytes),
        throwsA(isA<BondedFramingException>()),
      );
    });

    test('rejects a frame whose payload claim exceeds the cap', () {
      Uint8List bytes = encodeBondedFrame(sessionId: 1, seq: 0, linkId: 0);
      // Overwrite the on-wire payload length to a bogus value > cap.
      ByteData bd = ByteData.sublistView(bytes);
      bd.setUint16(22, kBondedMaxPayload + 1, Endian.big);
      expect(
        () => decodeBondedFrame(bytes),
        throwsA(isA<BondedFramingException>()),
      );
    });

    test('rejects truncation: payloadLen says more than we have', () {
      Uint8List bytes = encodeBondedFrame(
        sessionId: 1,
        seq: 0,
        linkId: 0,
        payload: Uint8List.fromList(<int>[0xAA, 0xBB]),
      );
      // Claim a longer payload than is present.
      ByteData bd = ByteData.sublistView(bytes);
      bd.setUint16(22, 32, Endian.big);
      expect(
        () => decodeBondedFrame(bytes),
        throwsA(isA<BondedFramingException>()),
      );
    });

    test('payload is a view, not a copy', () {
      Uint8List bytes = encodeBondedFrame(
        sessionId: 1,
        seq: 0,
        linkId: 0,
        payload: Uint8List.fromList(<int>[0x11, 0x22, 0x33]),
      );
      BondedFrame frame = decodeBondedFrame(bytes);
      // Mutating the source buffer mutates the view — that's the contract;
      // callers who need ownership copy explicitly.
      bytes[kBondedHeaderSize] = 0xFF;
      expect(frame.payload[0], 0xFF);
    });

    test('keepalive flag is exposed via the convenience getter', () {
      Uint8List bytes = encodeBondedFrame(
        sessionId: 1,
        seq: 0,
        linkId: 0,
        flags: BondedFlags.keepalive,
      );
      BondedFrame frame = decodeBondedFrame(bytes);
      expect(frame.isKeepalive, isTrue);
      expect(frame.isAck, isFalse);
    });

    test('returns a zero-length payload when payloadLen is 0', () {
      Uint8List bytes = encodeBondedFrame(sessionId: 1, seq: 0, linkId: 7);
      BondedFrame frame = decodeBondedFrame(bytes);
      expect(frame.payload, isEmpty);
      expect(frame.linkId, 7);
    });

    test('encode → decode is bit-exact for max-length payload', () {
      Uint8List body = Uint8List(kBondedMaxPayload);
      for (int i = 0; i < body.length; i++) {
        body[i] = (i * 31) & 0xff;
      }
      Uint8List bytes = encodeBondedFrame(
        sessionId: 1,
        seq: 0,
        linkId: 0,
        payload: body,
      );
      BondedFrame frame = decodeBondedFrame(bytes);
      expect(frame.payload, body);
    });
  });

  // Canned-bytes vectors that pin the cross-language wire contract. Any
  // mismatch with `speed-server/bonded/framing_test.go::TestEncode_KnownVectors`
  // is a wire-format bug that MUST be fixed in lockstep across all three
  // implementations before merging.
  group('cross-language vectors', () {
    test('empty payload, all zero matches the canonical vector', () {
      Uint8List bytes = encodeBondedFrame(sessionId: 0, seq: 0, linkId: 0);
      expect(_toHex(bytes), 'DA0101000000000000000000000000000000000000000000');
    });

    test('high-bit sessionId + ACK flag + 4-byte payload matches', () {
      Uint8List bytes = encodeBondedFrame(
        sessionId: 0xABCD000000000001,
        seq: 5,
        linkId: 1,
        flags: BondedFlags.ack,
        payload: Uint8List.fromList(<int>[0x10, 0x20, 0x30, 0x40]),
      );
      expect(
        _toHex(bytes),
        'DA010101ABCD00000000000100000000000000050001000410203040',
      );
    });

    test('keepalive carries a u64-LE inflight counter', () {
      Uint8List bytes = encodeBondedFrame(
        sessionId: 0x0102030405060708,
        seq: 0,
        linkId: 7,
        flags: BondedFlags.keepalive,
        payload: Uint8List.fromList(<int>[
          0x99,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
        ]),
      );
      expect(
        _toHex(bytes),
        'DA01010401020304050607080000000000000000000700089900000000000000',
      );
    });
  });
}

/// Hex-encode bytes as uppercase, no separators. Matches Go's `%X` so the
/// failure messages line up with the Go vector test.
String _toHex(Uint8List bytes) {
  StringBuffer buf = StringBuffer();
  for (int b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
  }
  return buf.toString();
}

// Behavior coverage for BondedReassembler. These tests describe the
// reordering / NAK / drop semantics that the bonded transport relies on
// and that the Swift mirror must match.

Uint8List _p(int byte, [int len = 4]) {
  return Uint8List.fromList(List<int>.filled(len, byte));
}

void bondedReassemblerSuite() {
  late BondedReassembler r;
  late List<Uint8List> received;
  late List<BondedNakRange> naks;
  late StreamSubscription<Uint8List> outboundSub;
  late StreamSubscription<BondedNakRange> nakSub;

  void wire(BondedReassembler reassembler) {
    received = <Uint8List>[];
    naks = <BondedNakRange>[];
    outboundSub = reassembler.outbound.listen(received.add);
    nakSub = reassembler.nakRequests.listen(naks.add);
  }

  tearDown(() async {
    await outboundSub.cancel();
    await nakSub.cancel();
    await r.dispose();
  });

  group('in-order delivery', () {
    test('emits payloads in the order they arrived', () async {
      r = BondedReassembler();
      wire(r);

      r.onPayload(seq: 0, payload: _p(0x01));
      r.onPayload(seq: 1, payload: _p(0x02));
      r.onPayload(seq: 2, payload: _p(0x03));

      await Future<void>.delayed(Duration.zero);
      expect(received.map((Uint8List b) => b.first).toList(), <int>[1, 2, 3]);
      expect(naks, isEmpty);
    });

    test('starts from initialNextSeq when configured', () async {
      r = BondedReassembler(initialNextSeq: 100);
      wire(r);

      r.onPayload(seq: 100, payload: _p(0x42));
      await Future<void>.delayed(Duration.zero);
      expect(received.single.first, 0x42);
    });
  });

  group('out-of-order delivery', () {
    test('buffers a future seq and emits it once the gap fills', () async {
      r = BondedReassembler();
      wire(r);

      r.onPayload(seq: 1, payload: _p(0xB1));
      // The 1-ahead packet shouldn't be emitted yet.
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);

      r.onPayload(seq: 0, payload: _p(0xB0));
      await Future<void>.delayed(Duration.zero);
      // Both should now be flushed in order.
      expect(received.map((Uint8List b) => b.first).toList(), <int>[
        0xB0,
        0xB1,
      ]);
    });

    test('emits a long suffix once the missing prefix arrives', () async {
      r = BondedReassembler();
      wire(r);

      for (int i = 5; i < 10; i++) {
        r.onPayload(seq: i, payload: _p(i));
      }
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);

      // Fill 0..4 — all 10 packets should now flush in one go.
      for (int i = 0; i < 5; i++) {
        r.onPayload(seq: i, payload: _p(i));
      }
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(10));
      expect(
        received.map((Uint8List b) => b.first).toList(),
        List<int>.generate(10, (int i) => i),
      );
    });
  });

  group('duplicate / stale handling', () {
    test('drops a payload whose seq is older than nextExpected', () async {
      r = BondedReassembler();
      wire(r);
      r.onPayload(seq: 0, payload: _p(0x00));
      r.onPayload(seq: 1, payload: _p(0x01));
      r.onPayload(seq: 0, payload: _p(0xFF)); // duplicate
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(2));
      expect(r.snapshot().droppedDuplicate, 1);
    });

    test('drops a buffered duplicate', () async {
      r = BondedReassembler();
      wire(r);
      // Build a gap so seq=2 stays buffered.
      r.onPayload(seq: 2, payload: _p(0xAA));
      r.onPayload(seq: 2, payload: _p(0xBB)); // duplicate buffered
      await Future<void>.delayed(Duration.zero);
      expect(r.snapshot().droppedDuplicate, 1);
      // Fill the gap; the first-buffered payload should win.
      r.onPayload(seq: 0, payload: _p(0x00));
      r.onPayload(seq: 1, payload: _p(0x11));
      await Future<void>.delayed(Duration.zero);
      expect(received.last.first, 0xAA);
    });

    test('drops seqs above the window', () async {
      r = BondedReassembler(windowSize: 16);
      wire(r);
      // 999 is way beyond the window from seq=0; must be dropped.
      r.onPayload(seq: 999, payload: _p(0xEE));
      await Future<void>.delayed(Duration.zero);
      expect(received, isEmpty);
      expect(r.snapshot().droppedStale, 1);
    });
  });

  group('NAK / gap-timer semantics', () {
    test('NAKs the missing prefix when a gap persists', () async {
      r = BondedReassembler(gapTimeout: const Duration(milliseconds: 20));
      wire(r);
      // Receive 3 with 0..2 missing.
      r.onPayload(seq: 3, payload: _p(0x03));
      // Within the gap window no NAK yet.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(naks, isEmpty);
      // After the gap expires, we should see a NAK for 0..2.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(naks, isNotEmpty);
      BondedNakRange range = naks.first;
      expect(range.startSeq, 0);
      expect(range.endSeq, 2);
      expect(range.length, 3);
    });

    test('cancels gap state when the hole fills before the timeout', () async {
      r = BondedReassembler(gapTimeout: const Duration(milliseconds: 100));
      wire(r);
      r.onPayload(seq: 1, payload: _p(0x11));
      // Fill quickly.
      r.onPayload(seq: 0, payload: _p(0x00));
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(naks, isEmpty);
      expect(received.length, 2);
    });

    test(
      'emits a follow-up NAK if the hole persists past two timeouts',
      () async {
        r = BondedReassembler(gapTimeout: const Duration(milliseconds: 15));
        wire(r);
        r.onPayload(seq: 5, payload: _p(0x05));
        await Future<void>.delayed(const Duration(milliseconds: 70));
        expect(naks.length, greaterThanOrEqualTo(2));
      },
    );
  });

  group('memory protection', () {
    test(
      'caps buffered bytes by evicting the highest seq when over budget',
      () async {
        // 3 payloads × 8 B each = 24 B; cap at 16 B → at most 2 in buffer.
        r = BondedReassembler(maxBufferedBytes: 16);
        wire(r);
        r.onPayload(seq: 3, payload: _p(0x33, 8));
        r.onPayload(seq: 5, payload: _p(0x55, 8));
        // The next add would push us over the cap. Highest (5) should be
        // evicted so the new one can settle in.
        r.onPayload(seq: 4, payload: _p(0x44, 8));
        await Future<void>.delayed(Duration.zero);
        BondedReassemblerStats stats = r.snapshot();
        expect(stats.bufferedCount, 2);
        expect(stats.droppedStale, greaterThanOrEqualTo(1));
      },
    );
  });

  group('lifecycle', () {
    test(
      'after dispose, additional packets are ignored and streams closed',
      () async {
        r = BondedReassembler();
        wire(r);
        r.onPayload(seq: 0, payload: _p(0x00));
        await r.dispose();
        r.onPayload(seq: 1, payload: _p(0x11));
        expect(r.isDisposed, isTrue);
        expect(received.length, 1);
      },
    );
  });
}

BondedLinkState _state(
  String id, {
  int wireId = 0,
  LinkPriority priority = LinkPriority.primary,
  LinkStatus status = LinkStatus.healthy,
  int weight = 1,
  double rttMs = 50.0,
  double bandwidthBps = 1_000_000.0,
  int inflightBytes = 0,
}) {
  return BondedLinkState(
    linkId: id,
    wireId: wireId,
    priority: priority,
    status: status,
    weight: weight,
    rttMs: rttMs,
    bandwidthBps: bandwidthBps,
    inflightBytes: inflightBytes,
  );
}

void bondedSchedulerModesSuite() {
  group('BondedModeStrategy.forMode', () {
    test('returns the matching V1 strategy class for each enum value', () {
      expect(
        BondedModeStrategy.forMode(BondingMode.speed),
        isA<SpeedStrategy>(),
      );
      expect(
        BondedModeStrategy.forMode(BondingMode.redundant),
        isA<RedundantStrategy>(),
      );
    });
  });

  group('SpeedStrategy', () {
    test('emits a single send via scheduler.pickLink', () {
      BondedScheduler scheduler = BondedScheduler();
      scheduler.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
          rttMs: 20,
          bandwidthBps: 10_000_000,
        ),
      ]);

      BondedChunkPlan plan = const SpeedStrategy().planChunk(
        bytes: 1024,
        scheduler: scheduler,
      );
      expect(plan.fanout, 1);
      expect(plan.sends.first.linkId, 'wifi');
      expect(scheduler.inflightForTest('wifi'), 1024);
    });

    test('empty plan when no healthy link is available', () {
      BondedScheduler scheduler = BondedScheduler();
      scheduler.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'cell',
          wireId: 2,
          priority: LinkPriority.primary,
          status: LinkStatus.unhealthy,
        ),
      ]);

      BondedChunkPlan plan = const SpeedStrategy().planChunk(
        bytes: 1024,
        scheduler: scheduler,
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  group('RedundantStrategy', () {
    test('fans out to every healthy primary link', () {
      BondedScheduler scheduler = BondedScheduler();
      scheduler.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
        ),
        BondedLinkState(
          linkId: 'cell',
          wireId: 2,
          priority: LinkPriority.primary,
          status: LinkStatus.healthy,
        ),
        BondedLinkState(
          linkId: 'wired',
          wireId: 3,
          priority: LinkPriority.secondary,
          status: LinkStatus.healthy,
        ),
      ]);

      BondedChunkPlan plan = const RedundantStrategy().planChunk(
        bytes: 512,
        scheduler: scheduler,
      );

      expect(plan.fanout, 2);
      Set<String> ids = plan.sends.map((BondedSendPlan p) => p.linkId).toSet();
      expect(ids, <String>{'wifi', 'cell'});
      expect(scheduler.inflightForTest('wifi'), 512);
      expect(scheduler.inflightForTest('cell'), 512);
      expect(scheduler.inflightForTest('wired'), 0);
    });

    test('falls back to secondary bucket when no primaries are healthy', () {
      BondedScheduler scheduler = BondedScheduler();
      scheduler.updateLinks(<BondedLinkState>[
        BondedLinkState(
          linkId: 'wifi',
          wireId: 1,
          priority: LinkPriority.primary,
          status: LinkStatus.unhealthy,
        ),
        BondedLinkState(
          linkId: 'cell',
          wireId: 2,
          priority: LinkPriority.secondary,
          status: LinkStatus.healthy,
        ),
      ]);

      BondedChunkPlan plan = const RedundantStrategy().planChunk(
        bytes: 256,
        scheduler: scheduler,
      );
      expect(plan.fanout, 1);
      expect(plan.sends.first.linkId, 'cell');
    });

    test('empty plan when no eligible link in any bucket', () {
      BondedScheduler scheduler = BondedScheduler();
      scheduler.updateLinks(<BondedLinkState>[
        BondedLinkState(linkId: 'wifi', wireId: 1, status: LinkStatus.disabled),
      ]);

      BondedChunkPlan plan = const RedundantStrategy().planChunk(
        bytes: 1024,
        scheduler: scheduler,
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  test('clampFractionForTest bounds the strategy fraction', () {
    expect(clampFractionForTest(0.0), 0.05);
    expect(clampFractionForTest(2.0), 1.0);
    expect(clampFractionForTest(0.5), 0.5);
  });

  group('BondedScheduler.pickLink', () {
    test('returns null when no links are configured', () {
      BondedScheduler s = BondedScheduler();
      expect(s.pickLink(bytes: 100), isNull);
    });

    test('returns null when zero or negative bytes requested', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[_state('a', wireId: 1)]);
      expect(s.pickLink(bytes: 0), isNull);
      expect(s.pickLink(bytes: -10), isNull);
    });

    test('returns null when every link is unhealthy or disabled', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state('a', wireId: 1, status: LinkStatus.unhealthy),
          _state('b', wireId: 2, status: LinkStatus.disabled),
        ]);
      expect(s.pickLink(bytes: 100), isNull);
    });

    test('prefers higher-bandwidth link in Speed mode', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state('slow', wireId: 1, bandwidthBps: 200_000.0),
          _state('fast', wireId: 2, bandwidthBps: 5_000_000.0),
        ]);
      BondedSchedulingDecision? d = s.pickLink(bytes: 1000);
      expect(d, isNotNull);
      expect(d!.linkId, 'fast');
      expect(d.wireId, 2);
      expect(d.wasRoundRobinFallback, isFalse);
    });

    test('penalizes higher-RTT link of equal bandwidth', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state('snappy', wireId: 1, rttMs: 20.0, bandwidthBps: 1_000_000.0),
          _state('lossy', wireId: 2, rttMs: 200.0, bandwidthBps: 1_000_000.0),
        ]);
      BondedSchedulingDecision? d = s.pickLink(bytes: 100);
      expect(d, isNotNull);
      expect(d!.linkId, 'lossy');
    });

    test('inflight bytes reduce future credit and shift the next pick', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state('a', wireId: 1, bandwidthBps: 1_000_000.0, rttMs: 50.0),
          _state('b', wireId: 2, bandwidthBps: 1_000_000.0, rttMs: 50.0),
        ]);
      s.pickLink(bytes: 40_000);
      BondedSchedulingDecision? second = s.pickLink(bytes: 1000);
      expect(second!.linkId, 'b');
    });

    test('completeSend frees inflight and restores credit', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state('a', wireId: 1, bandwidthBps: 1_000_000.0, rttMs: 50.0),
          _state('b', wireId: 2, bandwidthBps: 1_000_000.0, rttMs: 50.0),
        ]);
      s.pickLink(bytes: 49_000);
      BondedSchedulingDecision? p1 = s.pickLink(bytes: 100);
      expect(p1!.linkId, 'b');
      s.completeSend('a', 49_000);
      expect(s.inflightForTest('a'), 0);
    });

    test('completeSend clamps to zero, never goes negative', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[_state('a', wireId: 1)]);
      s.pickLink(bytes: 10);
      s.completeSend('a', 9999);
      expect(s.inflightForTest('a'), 0);
    });

    test('completeSend on unknown link is a no-op', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[_state('a', wireId: 1)]);
      s.completeSend('does-not-exist', 100);
    });
  });

  group('priority handling', () {
    test('uses only primary when any primary is healthy', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state('prim', wireId: 1),
          _state(
            'sec',
            wireId: 2,
            priority: LinkPriority.secondary,
            bandwidthBps: 10_000_000.0,
          ),
          _state('bk', wireId: 3, priority: LinkPriority.backup),
        ]);
      BondedSchedulingDecision? d = s.pickLink(bytes: 100);
      expect(d!.linkId, 'prim');
    });

    test('falls down to secondary when all primaries are unhealthy', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state('prim', wireId: 1, status: LinkStatus.unhealthy),
          _state('sec', wireId: 2, priority: LinkPriority.secondary),
        ]);
      BondedSchedulingDecision? d = s.pickLink(bytes: 100);
      expect(d!.linkId, 'sec');
    });

    test('skips never-priority links even when they look healthy', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state(
            'off',
            wireId: 1,
            priority: LinkPriority.never,
            bandwidthBps: 100_000_000.0,
          ),
          _state('on', wireId: 2),
        ]);
      BondedSchedulingDecision? d = s.pickLink(bytes: 100);
      expect(d!.linkId, 'on');
    });

    test('drops to backup when primary + secondary are gone', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state('prim', wireId: 1, status: LinkStatus.unhealthy),
          _state(
            'sec',
            wireId: 2,
            priority: LinkPriority.secondary,
            status: LinkStatus.unhealthy,
          ),
          _state('bk', wireId: 3, priority: LinkPriority.backup),
        ]);
      BondedSchedulingDecision? d = s.pickLink(bytes: 100);
      expect(d!.linkId, 'bk');
    });
  });

  group('round-robin fallback', () {
    test('flagged when two healthy links tie on credit', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state('a', wireId: 1, bandwidthBps: 1_000_000.0, rttMs: 50.0),
          _state('b', wireId: 2, bandwidthBps: 1_000_000.0, rttMs: 50.0),
        ]);
      BondedSchedulingDecision? first = s.pickLink(bytes: 100);
      expect(first!.wasRoundRobinFallback, isTrue);
    });

    test('RR alternates across consecutive picks with equal credit', () {
      BondedScheduler s = BondedScheduler();
      s.updateLinks(<BondedLinkState>[
        _state('a', wireId: 1, bandwidthBps: 1_000_000_000.0),
        _state('b', wireId: 2, bandwidthBps: 1_000_000_000.0),
        _state('c', wireId: 3, bandwidthBps: 1_000_000_000.0),
      ]);
      List<String> picks = <String>[];
      for (int i = 0; i < 6; i++) {
        BondedSchedulingDecision? d = s.pickLink(bytes: 1);
        picks.add(d!.linkId);
      }
      expect(picks.toSet(), <String>{'a', 'b', 'c'});
    });
  });

  group('updateLinks', () {
    test('preserves inflight for surviving links', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state('a', wireId: 1),
          _state('b', wireId: 2),
        ]);
      s.pickLink(bytes: 500);
      int totalInflight = s.inflightForTest('a') + s.inflightForTest('b');
      expect(totalInflight, 500);

      s.updateLinks(<BondedLinkState>[
        _state('a', wireId: 1, bandwidthBps: 999_999.0),
        _state('b', wireId: 2, bandwidthBps: 999_999.0),
      ]);
      expect(s.inflightForTest('a') + s.inflightForTest('b'), 500);
    });

    test('removed links lose their inflight (caller must drain first)', () {
      BondedScheduler s = BondedScheduler()
        ..updateLinks(<BondedLinkState>[
          _state('a', wireId: 1),
          _state('b', wireId: 2),
        ]);
      s.pickLink(bytes: 200);
      s.updateLinks(<BondedLinkState>[_state('a', wireId: 1)]);
      expect(s.linkCount, 1);
      expect(s.inflightForTest('b'), 0);
    });
  });

  group('credit minimums', () {
    test('bandwidth floor keeps a brand-new metric-less link in the race', () {
      BondedScheduler s = BondedScheduler(minBandwidthBps: 100_000.0);
      s.updateLinks(<BondedLinkState>[
        _state('cold', wireId: 1, bandwidthBps: 0.0, rttMs: 100.0),
      ]);
      double credit = s.creditForTest('cold');
      expect(credit, closeTo(10_000.0, 1.0));
    });

    test('rtt floor avoids division-by-zero on a loopback link', () {
      BondedScheduler s = BondedScheduler(minRttMs: 1.0);
      s.updateLinks(<BondedLinkState>[
        _state('lo', wireId: 1, rttMs: 0.0, bandwidthBps: 10_000_000.0),
      ]);
      expect(s.creditForTest('lo'), closeTo(10_000.0, 1.0));
    });
  });

  group('BondedLinkState.fromLink', () {
    test('falls back to defaults when no metric is supplied', () {
      BondedLinkState s = BondedLinkState.fromLink(
        const Link(id: 'wifi', label: 'Wi-Fi'),
        wireId: 7,
      );
      expect(s.wireId, 7);
      expect(s.rttMs, 50.0);
      expect(s.bandwidthBps, 1_000_000.0);
    });
  });
}

// End-to-end stripe + reassemble across the in-process bonded loopback.
//
// This is the integration test that pins down "the bonded transport
// actually works as a unit." It exercises the scheduler, framing, and
// reassembler together over two virtual links of different latencies, with
// and without loss. Slow on purpose — we use small real-time delays rather
// than fake async so the test reflects the real Timer-driven gap and
// keepalive paths.

Uint8List _payload(int seed, int len) {
  Uint8List out = Uint8List(len);
  // Deterministic pseudo-random fill so equality checks are meaningful.
  math.Random rng = math.Random(seed);
  for (int i = 0; i < len; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

void localBondedLoopbackSuite() {
  group('LocalBondedLoopback', () {
    test(
      'stripes a 64 KB stream across two healthy links and reassembles it',
      () async {
        LocalBondedLoopback loop = LocalBondedLoopback(
          links: const <VirtualLinkSpec>[
            // Bandwidth narrow enough that 64 KB saturates credit on each
            // link and forces the scheduler to alternate. Speedify uses a
            // richer BBR-style pacing — v0 is satisfied with "more than one
            // link got traffic".
            VirtualLinkSpec(
              linkId: 'wifi',
              wireId: 1,
              latencyMs: 10,
              bandwidthBps: 200_000.0,
            ),
            VirtualLinkSpec(
              linkId: 'cell',
              wireId: 2,
              latencyMs: 25,
              bandwidthBps: 200_000.0,
            ),
          ],
        )..start();

        try {
          Uint8List stream = _payload(1, 64 * 1024);
          int scheduled = loop.client.send(stream);
          expect(scheduled, stream.length);

          await loop.waitForServerBytes(
            stream.length,
            timeout: const Duration(seconds: 10),
          );

          Uint8List joined = joinReceived(loop.serverReceived);
          expect(joined.length, stream.length);
          expect(joined, stream);

          // Both links should have carried some bytes — otherwise it's not
          // really bonded.
          Map<String, int> bytesPerLink = loop.client.snapshot().bytesPerLink;
          expect(bytesPerLink['wifi'], greaterThan(0));
          expect(bytesPerLink['cell'], greaterThan(0));
        } finally {
          await loop.dispose();
        }
      },
    );

    test(
      'survives loss on the only available link via NAK retransmits',
      () async {
        // Single lossy link to force every packet through the dropper. The
        // scheduler can't route around the problem, so the reassembler MUST
        // close every hole via NAK retransmits or the stream stalls.
        LocalBondedLoopback loop = LocalBondedLoopback(
          links: const <VirtualLinkSpec>[
            VirtualLinkSpec(
              linkId: 'wifi',
              wireId: 1,
              latencyMs: 10,
              loss: 0.40,
              bandwidthBps: 5_000_000.0,
            ),
          ],
          random: math.Random(0xDEAD),
        )..start(reassemblerGapTimeout: const Duration(milliseconds: 40));

        try {
          Uint8List stream = _payload(2, 4 * 1024);
          loop.client.send(stream);
          await loop.waitForServerBytes(
            stream.length,
            timeout: const Duration(seconds: 10),
          );

          Uint8List joined = joinReceived(loop.serverReceived);
          expect(joined.length, stream.length);
          expect(joined, stream);

          // The lossy link MUST have dropped at least one packet.
          expect(loop.clientPacketsDropped, greaterThan(0));
          // And the session MUST have retransmitted to recover.
          expect(loop.client.snapshot().retransmissions, greaterThan(0));
        } finally {
          await loop.dispose();
        }
      },
    );

    test(
      'falls through to the only healthy link when the other is 100% lossy',
      () async {
        LocalBondedLoopback loop = LocalBondedLoopback(
          links: const <VirtualLinkSpec>[
            VirtualLinkSpec(
              linkId: 'wifi',
              wireId: 1,
              latencyMs: 10,
              loss: 1.0,
            ),
            VirtualLinkSpec(linkId: 'cell', wireId: 2, latencyMs: 25),
          ],
        )..start(reassemblerGapTimeout: const Duration(milliseconds: 50));

        try {
          Uint8List stream = _payload(3, 4 * 1024);
          loop.client.send(stream);
          await loop.waitForServerBytes(
            stream.length,
            timeout: const Duration(seconds: 8),
          );

          Uint8List joined = joinReceived(loop.serverReceived);
          expect(joined, stream);
        } finally {
          await loop.dispose();
        }
      },
    );

    test(
      'out-of-order arrival from a slow link still reassembles correctly',
      () async {
        // Big latency gap between the two links forces out-of-order delivery.
        LocalBondedLoopback loop = LocalBondedLoopback(
          links: const <VirtualLinkSpec>[
            VirtualLinkSpec(linkId: 'fast', wireId: 1, latencyMs: 5),
            VirtualLinkSpec(linkId: 'slow', wireId: 2, latencyMs: 80),
          ],
        )..start(reassemblerGapTimeout: const Duration(milliseconds: 200));

        try {
          Uint8List stream = _payload(4, 16 * 1024);
          loop.client.send(stream);
          await loop.waitForServerBytes(
            stream.length,
            timeout: const Duration(seconds: 8),
          );

          Uint8List joined = joinReceived(loop.serverReceived);
          expect(joined, stream);
        } finally {
          await loop.dispose();
        }
      },
    );

    test(
      'Redundant mode duplicates each chunk to every healthy link and dedups '
      'on the receiver',
      () async {
        // Two clean links, Redundant mode. Each chunk should go out on
        // BOTH links, but the receiver must emit the stream exactly once
        // — the reassembler's duplicate counter MUST be > 0.
        LocalBondedLoopback loop = LocalBondedLoopback(
          links: const <VirtualLinkSpec>[
            VirtualLinkSpec(linkId: 'wifi', wireId: 1, latencyMs: 10),
            VirtualLinkSpec(linkId: 'cell', wireId: 2, latencyMs: 25),
          ],
        )..start(mode: BondingMode.redundant);

        try {
          Uint8List stream = _payload(5, 4 * 1024);
          loop.client.send(stream);
          await loop.waitForServerBytes(
            stream.length,
            timeout: const Duration(seconds: 8),
          );

          // Wait long enough for the slower link's copy to arrive AFTER
          // the fast link's copy has already advanced _nextSeq. Without
          // this delay we'd snapshot before dedup has a chance to fire.
          await Future<void>.delayed(const Duration(milliseconds: 60));

          // 1. End-to-end stream MUST come through bit-exact even though
          //    every payload was sent twice.
          Uint8List joined = joinReceived(loop.serverReceived);
          expect(joined.length, stream.length);
          expect(joined, stream);

          // 2. Both links MUST have carried bytes (fan-out happened).
          Map<String, int> bytesPerLink = loop.client.snapshot().bytesPerLink;
          expect(bytesPerLink['wifi'], greaterThan(0));
          expect(bytesPerLink['cell'], greaterThan(0));

          // 3. The session MUST report duplicate fan-outs.
          expect(
            loop.client.snapshot().duplicateFanouts,
            greaterThan(0),
            reason: 'Redundant should fan out every chunk to every primary',
          );

          // 4. The receiver's reassembler MUST have seen — and dropped —
          //    duplicate seqs. This is the core Phase 10.6 invariant.
          expect(
            loop.server.reassembler.snapshot().droppedDuplicate,
            greaterThan(0),
            reason: 'Reassembler should dedup duplicate seqs from Redundant',
          );
        } finally {
          await loop.dispose();
        }
      },
    );

    test(
      'setMode at runtime swaps strategies without dropping the stream',
      () async {
        LocalBondedLoopback loop = LocalBondedLoopback(
          links: const <VirtualLinkSpec>[
            VirtualLinkSpec(
              linkId: 'wifi',
              wireId: 1,
              latencyMs: 10,
              bandwidthBps: 200_000.0,
            ),
            VirtualLinkSpec(
              linkId: 'cell',
              wireId: 2,
              latencyMs: 20,
              bandwidthBps: 200_000.0,
            ),
          ],
        )..start();

        try {
          // Speed mode first half.
          Uint8List first = _payload(6, 16 * 1024);
          loop.client.send(first);

          // Wait until at least the first chunk has been transmitted
          // before flipping modes — we want a *mid-stream* change.
          await Future<void>.delayed(const Duration(milliseconds: 50));

          loop.client.setMode(BondingMode.redundant);
          expect(loop.client.strategy.mode, BondingMode.redundant);

          Uint8List second = _payload(7, 16 * 1024);
          loop.client.send(second);

          await loop.waitForServerBytes(
            first.length + second.length,
            timeout: const Duration(seconds: 10),
          );

          Uint8List joined = joinReceived(loop.serverReceived);
          expect(joined.length, first.length + second.length);
          expect(joined.sublist(0, first.length), first);
          expect(joined.sublist(first.length), second);
        } finally {
          await loop.dispose();
        }
      },
    );
  });
}

// Phase 9 wiring test for `BondedSession.sealer` / `BondedSession.opener`.
//
// The point of this test is to prove the hook plumbing — not to exercise
// real AEAD. The Dart `cryptography` package is async-only, but the
// session's seal/open callbacks are synchronous (so production paths can
// be driven by a pre-computed key without awaiting). To keep the test
// deterministic and fast we use a trivial reversible byte transform (XOR
// with 0xAA), which is enough to catch:
//
//   * outbound frame bytes go through `sealer` before delivery
//   * inbound wire bytes go through `opener` before decoding
//   * mismatched / missing hooks drop the bytes silently (no crash)
//
// Cross-language AEAD parity is proven separately in
// `test/crypto/noise_cross_test.dart` and
// `speed-server/crypto/noise_cross_test.go`.

Uint8List _xorTransform(Uint8List src) {
  Uint8List out = Uint8List(src.length);
  for (int i = 0; i < src.length; i++) {
    out[i] = src[i] ^ 0xAA;
  }
  return out;
}

void sealedBondedLoopbackSuite() {
  test(
    'sealed bonded loopback round-trips through reversible transform',
    () async {
      LocalBondedLoopback loopback = LocalBondedLoopback(
        links: const <VirtualLinkSpec>[
          VirtualLinkSpec(linkId: 'wifi', wireId: 1, latencyMs: 5),
          VirtualLinkSpec(linkId: 'cell', wireId: 2, latencyMs: 10),
        ],
        // Both sides "seal" by XORing the frame bytes. Both sides "open"
        // by undoing the XOR. End-to-end the application bytes must be
        // identical on the server side.
        clientSealer: _xorTransform,
        serverOpener: _xorTransform,
        serverSealer: _xorTransform,
        clientOpener: _xorTransform,
      );
      loopback.start();

      Uint8List payload = Uint8List.fromList(
        List<int>.generate(8 * 1024, (int i) => i & 0xFF),
      );
      int sent = loopback.client.send(payload);
      expect(sent, payload.length);
      await loopback.waitForServerBytes(
        payload.length,
        timeout: const Duration(seconds: 4),
      );
      expect(
        joinReceived(loopback.serverReceived),
        payload,
        reason: 'sealer/opener pair must round-trip every byte',
      );
      await loopback.dispose();
    },
  );

  test('mismatched sealer/opener pair causes all frames to drop', () async {
    // Client seals with XOR 0xAA but server tries to open with a no-op
    // transform — server side will see garbled framing and drop every
    // frame. We assert nothing arrives within a short window.
    LocalBondedLoopback loopback = LocalBondedLoopback(
      links: const <VirtualLinkSpec>[
        VirtualLinkSpec(linkId: 'wifi', wireId: 1, latencyMs: 5),
      ],
      clientSealer: _xorTransform,
      // Note: serverOpener intentionally NOT wired — bytes arrive XORed
      // and the framing decoder rejects them.
    );
    loopback.start();
    Uint8List payload = Uint8List(2 * 1024);
    int sent = loopback.client.send(payload);
    expect(sent, payload.length);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      loopback.serverReceived,
      isEmpty,
      reason: 'a missing opener must drop the bytes silently',
    );
    await loopback.dispose();
  });
}

void main() {
  group('bonded framing', bondedFramingSuite);
  group('bonded reassembler', bondedReassemblerSuite);
  group('bonded scheduler and modes', bondedSchedulerModesSuite);
  group('local bonded loopback', localBondedLoopbackSuite);
  group('sealed bonded loopback', sealedBondedLoopbackSuite);
}
