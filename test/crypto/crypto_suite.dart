import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/crypto/noise.dart';
import 'package:arcane_dispatch/crypto/replay.dart';
import 'package:arcane_dispatch/crypto/seal.dart';

const String crossInitStaticSeed =
    '0100000000000000000000000000000000000000000000000000000000000000';
const String crossInitEphSeed =
    '0200000000000000000000000000000000000000000000000000000000000000';
const String crossRespStaticSeed =
    '0300000000000000000000000000000000000000000000000000000000000000';
const String crossRespEphSeed =
    '0400000000000000000000000000000000000000000000000000000000000000';
const String crossMsg1PayloadHex = '68656c6c6f20736572766572';
const String crossMsg2PayloadHex = '68656c6c6f20636c69656e74';
const String expectedMsg1Hex =
    '2fe57da347cd62431528daac5fbb290730fff684afc4cfc2ed90995f58cb3b74'
    'f3d31b3ecff438842427efae43f49ef54d63e7b8eb23c659f511beea7ee60605'
    'aebde724350d862a7d8c19e639ee18c9cd51ecb9e4f4948f626959d21eb4c5b2'
    'e6b4f3e64e37e230a5e49603';
const String expectedMsg2Hex =
    '2fe57da347cd62431528daac5fbb290730fff684afc4cfc2ed90995f58cb3b74'
    '1550103823047d8ea658eadbd61f240eff8a48f1ef4e79213b9801b6';
const String expectedInitSendKeyHex =
    '80259c98a8360079177a63edcd0a05ea335b9ba51ce9a2b85f09d5dd89374c6f';
const String expectedInitRecvKeyHex =
    '60eaa771f1e0b84abdfd8e36b7e12938d59b19eda1bf69dddeaadeb321531d5b';
const String expectedFirstSealedHex =
    'da02010000000000000000009ecd2ced2bdf75a2cffc10c4d9bdfe510c2bfa225e';

Uint8List _seed(int b) {
  Uint8List s = Uint8List(32);
  s[0] = b;
  return s;
}

Future<
  ({HandshakeState init, HandshakeState resp, NoiseKeypair iS, NoiseKeypair rS})
>
_seedHandshake() async {
  NoiseKeypair iS = await NoiseKeypair.fromSeed(_seed(1));
  NoiseKeypair rS = await NoiseKeypair.fromSeed(_seed(3));
  HandshakeState init = await HandshakeState.initiator(s: iS, rs: rS.public);
  await init.setTestEphemeral(_seed(2));
  HandshakeState resp = await HandshakeState.responder(s: rS);
  await resp.setTestEphemeral(_seed(4));
  return (init: init, resp: resp, iS: iS, rS: rS);
}

Uint8List _hexToBytes(String s) {
  if (s.length % 2 != 0) {
    throw ArgumentError('hex length must be even: ${s.length}');
  }
  Uint8List out = Uint8List(s.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(Uint8List b) {
  StringBuffer sb = StringBuffer();
  for (int x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _seedFromHex(String s) {
  Uint8List b = _hexToBytes(s);
  if (b.length != 32) {
    throw ArgumentError('seed must be 32 bytes, got ${b.length}');
  }
  return b;
}

void main() {
  group('ReplayWindow', () {
    test('accepts sequential new nonces', () {
      ReplayWindow w = ReplayWindow(size: 64);
      for (int i = 0; i < 64; i++) {
        w.check(i);
      }
    });

    test('rejects exact replay', () {
      ReplayWindow w = ReplayWindow(size: 64);
      w.check(42);
      expect(() => w.check(42), throwsA(isA<ReplayDetectedException>()));
    });

    test('accepts out-of-order nonces within window', () {
      ReplayWindow w = ReplayWindow(size: 32);
      w.check(10);
      w.check(5);
      expect(() => w.check(5), throwsA(isA<ReplayDetectedException>()));
    });

    test('rejects nonces below the window edge', () {
      ReplayWindow w = ReplayWindow(size: 8);
      w.check(100);
      expect(() => w.check(80), throwsA(isA<NonceTooOldException>()));
    });

    test('handles large forward jumps', () {
      ReplayWindow w = ReplayWindow(size: 128);
      w.check(0);
      w.check(1000000);
      expect(() => w.check(0), throwsA(isA<NonceTooOldException>()));
      w.check(999999);
    });

    test('size <= 0 falls back to default window', () {
      ReplayWindow w = ReplayWindow(size: -1);
      expect(w.size, defaultReplayWindow);
    });
  });

  group('Noise IK handshake', () {
    test('payloads round-trip across both messages', () async {
      ({
        HandshakeState init,
        HandshakeState resp,
        NoiseKeypair iS,
        NoiseKeypair rS,
      })
      s = await _seedHandshake();
      Uint8List msg1 = await s.init.writeMessage1(
        Uint8List.fromList('hello server'.codeUnits),
      );
      Uint8List recv1 = await s.resp.readMessage1(msg1);
      expect(String.fromCharCodes(recv1), 'hello server');

      ({Uint8List msg, NoiseTransport transport}) resp = await s.resp
          .writeMessage2(Uint8List.fromList('hello client'.codeUnits));
      ({Uint8List payload, NoiseTransport transport}) read = await s.init
          .readMessage2(resp.msg);
      expect(String.fromCharCodes(read.payload), 'hello client');

      ({int nonce, Uint8List ciphertext}) sealed = await read.transport.seal(
        null,
        Uint8List.fromList('ping'.codeUnits),
      );
      Uint8List plain = await resp.transport.open(
        sealed.nonce,
        null,
        sealed.ciphertext,
      );
      expect(String.fromCharCodes(plain), 'ping');
    });

    test('responder learns initiator static after readMessage1', () async {
      ({
        HandshakeState init,
        HandshakeState resp,
        NoiseKeypair iS,
        NoiseKeypair rS,
      })
      s = await _seedHandshake();
      Uint8List msg1 = await s.init.writeMessage1(Uint8List(0));
      await s.resp.readMessage1(msg1);
      expect(s.resp.remoteStatic, s.iS.public);
    });

    test('writeMessage1 rejects oversized payload', () async {
      ({
        HandshakeState init,
        HandshakeState resp,
        NoiseKeypair iS,
        NoiseKeypair rS,
      })
      s = await _seedHandshake();
      expect(
        () => s.init.writeMessage1(Uint8List(maxHandshakePayload + 1)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('tampered ciphertext fails AEAD', () async {
      ({
        HandshakeState init,
        HandshakeState resp,
        NoiseKeypair iS,
        NoiseKeypair rS,
      })
      s = await _seedHandshake();
      Uint8List msg1 = await s.init.writeMessage1(Uint8List(0));
      msg1[40] ^= 0x80;
      expect(() => s.resp.readMessage1(msg1), throwsA(isA<Object>()));
    });
  });

  group('Sealed frame', () {
    test('seal + openSealed round-trip', () async {
      ({
        HandshakeState init,
        HandshakeState resp,
        NoiseKeypair iS,
        NoiseKeypair rS,
      })
      s = await _seedHandshake();
      await s.resp.readMessage1(await s.init.writeMessage1(Uint8List(0)));
      ({Uint8List msg, NoiseTransport transport}) m2 = await s.resp
          .writeMessage2(Uint8List(0));
      ({Uint8List payload, NoiseTransport transport}) r2 = await s.init
          .readMessage2(m2.msg);

      Uint8List plain = Uint8List.fromList('hello sealed'.codeUnits);
      Uint8List wire = await seal(r2.transport, plain);
      expect(wire.length, greaterThan(sealedHeaderSize));

      SealedHeader hdr = decodeSealedHeader(
        Uint8List.sublistView(wire, 0, sealedHeaderSize),
      );
      expect(hdr.magic, sealedMagic);
      expect(hdr.version, sealedVersion);
      expect(hdr.nonce, 0);

      Uint8List got = await openSealed(
        m2.transport,
        hdr,
        Uint8List.sublistView(wire, sealedHeaderSize),
      );
      expect(String.fromCharCodes(got), 'hello sealed');
    });

    test('decodeSealedHeader rejects short / bad magic', () async {
      expect(() => decodeSealedHeader(Uint8List(3)), throwsStateError);
      Uint8List bogus = Uint8List(sealedHeaderSize);
      bogus[0] = 0xDE;
      bogus[1] = 0xAD;
      expect(() => decodeSealedHeader(bogus), throwsStateError);
    });

    test('header tampering fails AEAD', () async {
      ({
        HandshakeState init,
        HandshakeState resp,
        NoiseKeypair iS,
        NoiseKeypair rS,
      })
      s = await _seedHandshake();
      await s.resp.readMessage1(await s.init.writeMessage1(Uint8List(0)));
      ({Uint8List msg, NoiseTransport transport}) m2 = await s.resp
          .writeMessage2(Uint8List(0));
      ({Uint8List payload, NoiseTransport transport}) r2 = await s.init
          .readMessage2(m2.msg);
      Uint8List wire = await seal(
        r2.transport,
        Uint8List.fromList('hello'.codeUnits),
      );
      wire[4] ^= 0x80;
      SealedHeader hdr = decodeSealedHeader(
        Uint8List.sublistView(wire, 0, sealedHeaderSize),
      );
      expect(
        () => openSealed(
          m2.transport,
          hdr,
          Uint8List.sublistView(wire, sealedHeaderSize),
        ),
        throwsA(isA<Object>()),
      );
    });
  });

  group('Noise cross-language vectors', () {
    test('Noise IK + sealed-frame matches Go-captured wire bytes', () async {
      NoiseKeypair initStatic = await NoiseKeypair.fromSeed(
        _seedFromHex(crossInitStaticSeed),
      );
      NoiseKeypair respStatic = await NoiseKeypair.fromSeed(
        _seedFromHex(crossRespStaticSeed),
      );

      HandshakeState init = await HandshakeState.initiator(
        s: initStatic,
        rs: respStatic.public,
      );
      await init.setTestEphemeral(_seedFromHex(crossInitEphSeed));

      HandshakeState resp = await HandshakeState.responder(s: respStatic);
      await resp.setTestEphemeral(_seedFromHex(crossRespEphSeed));

      Uint8List msg1 = await init.writeMessage1(
        _hexToBytes(crossMsg1PayloadHex),
      );
      expect(
        _bytesToHex(msg1),
        expectedMsg1Hex,
        reason: 'message1 wire bytes drifted from Go canonical output',
      );

      Uint8List recv1 = await resp.readMessage1(msg1);
      expect(_bytesToHex(recv1), crossMsg1PayloadHex);

      ({Uint8List msg, NoiseTransport transport}) resp2 = await resp
          .writeMessage2(_hexToBytes(crossMsg2PayloadHex));
      expect(
        _bytesToHex(resp2.msg),
        expectedMsg2Hex,
        reason: 'message2 wire bytes drifted from Go canonical output',
      );

      ({Uint8List payload, NoiseTransport transport}) initRead = await init
          .readMessage2(resp2.msg);
      expect(_bytesToHex(initRead.payload), crossMsg2PayloadHex);
      expect(
        _bytesToHex(initRead.transport.sendKey),
        expectedInitSendKeyHex,
        reason: 'initiator sendKey drifted from Go canonical',
      );
      expect(
        _bytesToHex(initRead.transport.recvKey),
        expectedInitRecvKeyHex,
        reason: 'initiator recvKey drifted from Go canonical',
      );
      expect(
        _bytesToHex(resp2.transport.recvKey),
        _bytesToHex(initRead.transport.sendKey),
      );
      expect(
        _bytesToHex(resp2.transport.sendKey),
        _bytesToHex(initRead.transport.recvKey),
      );

      Uint8List wire = await seal(
        initRead.transport,
        Uint8List.fromList('hello'.codeUnits),
      );
      expect(
        _bytesToHex(wire),
        expectedFirstSealedHex,
        reason: 'first sealed frame drifted from Go canonical',
      );

      SealedHeader hdr = decodeSealedHeader(
        Uint8List.sublistView(wire, 0, sealedHeaderSize),
      );
      Uint8List plain = await openSealed(
        resp2.transport,
        hdr,
        Uint8List.sublistView(wire, sealedHeaderSize),
      );
      expect(String.fromCharCodes(plain), 'hello');
    });
  });
}
