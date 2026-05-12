// Behavior coverage for BondedReassembler. These tests describe the
// reordering / NAK / drop semantics that the bonded transport relies on
// and that the Swift mirror must match.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/bonded/bonded_reassembler.dart';

Uint8List _p(int byte, [int len = 4]) {
  return Uint8List.fromList(List<int>.filled(len, byte));
}

void main() {
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
      expect(received.map((Uint8List b) => b.first).toList(), <int>[0xB0, 0xB1]);
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
      expect(received.map((Uint8List b) => b.first).toList(),
          List<int>.generate(10, (int i) => i));
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

    test('emits a follow-up NAK if the hole persists past two timeouts',
        () async {
      r = BondedReassembler(gapTimeout: const Duration(milliseconds: 15));
      wire(r);
      r.onPayload(seq: 5, payload: _p(0x05));
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(naks.length, greaterThanOrEqualTo(2));
    });
  });

  group('memory protection', () {
    test('caps buffered bytes by evicting the highest seq when over budget',
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
    });
  });

  group('lifecycle', () {
    test('after dispose, additional packets are ignored and streams closed',
        () async {
      r = BondedReassembler();
      wire(r);
      r.onPayload(seq: 0, payload: _p(0x00));
      await r.dispose();
      r.onPayload(seq: 1, payload: _p(0x11));
      expect(r.isDisposed, isTrue);
      expect(received.length, 1);
    });
  });
}
