// Wire-format round-trip + edge-case coverage for the bonded protocol v0.
//
// These tests are the spec contract for both `bonded_framing.dart` and its
// Swift mirror at `macos/ArcaneDispatchTunnel/Bonded/BondedFraming.swift`. If
// you change a byte offset, change them both and update this file.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/bonded/bonded_framing.dart';

void main() {
  group('encodeBondedFrame', () {
    test('emits a 24-byte header for an empty payload', () {
      Uint8List bytes = encodeBondedFrame(
        sessionId: 0,
        seq: 0,
        linkId: 0,
      );
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
      Uint8List payload =
          Uint8List.fromList(List<int>.generate(64, (int i) => (i * 7) & 0xff));
      Uint8List bytes = encodeBondedFrame(
        sessionId: 9999,
        seq: 123456789,
        linkId: 3,
        flags: BondedFlags.realtime,
        payload: payload,
      );
      BondedFrame frame = decodeBondedFrame(bytes);
      expect(frame.magic, kBondedMagic);
      expect(frame.version, kBondedProtocolVersion);
      expect(frame.flags, BondedFlags.realtime);
      expect(frame.isRealtime, isTrue);
      expect(frame.isAck, isFalse);
      expect(frame.sessionId, 9999);
      expect(frame.seq, 123456789);
      expect(frame.linkId, 3);
      expect(frame.payload, payload);
    });

    test('rejects a header that is too short', () {
      Uint8List bytes = Uint8List(kBondedHeaderSize - 1);
      expect(() => decodeBondedFrame(bytes),
          throwsA(isA<BondedFramingException>()));
    });

    test('rejects a frame with the wrong magic', () {
      Uint8List bytes = encodeBondedFrame(sessionId: 1, seq: 0, linkId: 0);
      bytes[0] = 0x00;
      bytes[1] = 0x00;
      expect(() => decodeBondedFrame(bytes),
          throwsA(isA<BondedFramingException>()));
    });

    test('rejects a frame with a future protocol version', () {
      Uint8List bytes = encodeBondedFrame(sessionId: 1, seq: 0, linkId: 0);
      bytes[2] = kBondedProtocolVersion + 1;
      expect(() => decodeBondedFrame(bytes),
          throwsA(isA<BondedFramingException>()));
    });

    test('rejects a frame whose payload claim exceeds the cap', () {
      Uint8List bytes = encodeBondedFrame(sessionId: 1, seq: 0, linkId: 0);
      // Overwrite the on-wire payload length to a bogus value > cap.
      ByteData bd = ByteData.sublistView(bytes);
      bd.setUint16(22, kBondedMaxPayload + 1, Endian.big);
      expect(() => decodeBondedFrame(bytes),
          throwsA(isA<BondedFramingException>()));
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
      expect(() => decodeBondedFrame(bytes),
          throwsA(isA<BondedFramingException>()));
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
      expect(_toHex(bytes),
          'DA0101000000000000000000000000000000000000000000');
    });

    test('high-bit sessionId + ACK flag + 4-byte payload matches', () {
      Uint8List bytes = encodeBondedFrame(
        sessionId: 0xABCD000000000001,
        seq: 5,
        linkId: 1,
        flags: BondedFlags.ack,
        payload: Uint8List.fromList(<int>[0x10, 0x20, 0x30, 0x40]),
      );
      expect(_toHex(bytes),
          'DA010101ABCD00000000000100000000000000050001000410203040');
    });

    test('keepalive carries a u64-LE inflight counter', () {
      Uint8List bytes = encodeBondedFrame(
        sessionId: 0x0102030405060708,
        seq: 0,
        linkId: 7,
        flags: BondedFlags.keepalive,
        payload: Uint8List.fromList(
            <int>[0x99, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
      );
      expect(_toHex(bytes),
          'DA01010401020304050607080000000000000000000700089900000000000000');
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
