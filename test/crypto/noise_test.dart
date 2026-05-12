// Round-trip tests for the Dart Noise IK + seal + replay implementation.
//
// Cross-language vector parity with the Go side lives in
// `noise_cross_test.dart`.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/crypto/noise.dart';
import 'package:arcane_dispatch/crypto/seal.dart';

Uint8List _seed(int b) {
  Uint8List s = Uint8List(32);
  s[0] = b;
  return s;
}

Future<({HandshakeState init, HandshakeState resp, NoiseKeypair iS, NoiseKeypair rS})>
    _seedHandshake() async {
  NoiseKeypair iS = await NoiseKeypair.fromSeed(_seed(1));
  NoiseKeypair rS = await NoiseKeypair.fromSeed(_seed(3));
  HandshakeState init = await HandshakeState.initiator(s: iS, rs: rS.public);
  await init.setTestEphemeral(_seed(2));
  HandshakeState resp = await HandshakeState.responder(s: rS);
  await resp.setTestEphemeral(_seed(4));
  return (init: init, resp: resp, iS: iS, rS: rS);
}

void main() {
  group('Noise IK handshake', () {
    test('payloads round-trip across both messages', () async {
      var s = await _seedHandshake();
      Uint8List msg1 = await s.init.writeMessage1(Uint8List.fromList(
          'hello server'.codeUnits));
      Uint8List recv1 = await s.resp.readMessage1(msg1);
      expect(String.fromCharCodes(recv1), 'hello server');

      var resp = await s.resp.writeMessage2(
          Uint8List.fromList('hello client'.codeUnits));
      var read = await s.init.readMessage2(resp.msg);
      expect(String.fromCharCodes(read.payload), 'hello client');

      // Transports are now exchangeable: encrypt with one side's
      // sendKey, decrypt with the other side's recvKey.
      var sealed =
          await read.transport.seal(null, Uint8List.fromList('ping'.codeUnits));
      Uint8List plain =
          await resp.transport.open(sealed.nonce, null, sealed.ciphertext);
      expect(String.fromCharCodes(plain), 'ping');
    });

    test('responder learns initiator static after readMessage1', () async {
      var s = await _seedHandshake();
      Uint8List msg1 = await s.init.writeMessage1(Uint8List(0));
      await s.resp.readMessage1(msg1);
      expect(s.resp.remoteStatic, s.iS.public);
    });

    test('writeMessage1 rejects oversized payload', () async {
      var s = await _seedHandshake();
      expect(
        () => s.init.writeMessage1(Uint8List(maxHandshakePayload + 1)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('tampered ciphertext fails AEAD', () async {
      var s = await _seedHandshake();
      Uint8List msg1 = await s.init.writeMessage1(Uint8List(0));
      // Flip a bit in the encrypted static.
      msg1[40] ^= 0x80;
      expect(
        () => s.resp.readMessage1(msg1),
        throwsA(isA<Object>()),
      );
    });
  });

  group('Sealed frame', () {
    test('seal + openSealed round-trip', () async {
      var s = await _seedHandshake();
      await s.resp.readMessage1(await s.init.writeMessage1(Uint8List(0)));
      var m2 = await s.resp.writeMessage2(Uint8List(0));
      var r2 = await s.init.readMessage2(m2.msg);

      Uint8List plain = Uint8List.fromList('hello sealed'.codeUnits);
      Uint8List wire = await seal(r2.transport, plain);
      expect(wire.length, greaterThan(sealedHeaderSize));

      SealedHeader hdr = decodeSealedHeader(
          Uint8List.sublistView(wire, 0, sealedHeaderSize));
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
      var s = await _seedHandshake();
      await s.resp.readMessage1(await s.init.writeMessage1(Uint8List(0)));
      var m2 = await s.resp.writeMessage2(Uint8List(0));
      var r2 = await s.init.readMessage2(m2.msg);
      Uint8List wire = await seal(
          r2.transport, Uint8List.fromList('hello'.codeUnits));
      // Flip a nonce byte.
      wire[4] ^= 0x80;
      SealedHeader hdr = decodeSealedHeader(
          Uint8List.sublistView(wire, 0, sealedHeaderSize));
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
}
