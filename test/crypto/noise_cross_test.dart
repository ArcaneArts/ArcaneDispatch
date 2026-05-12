// Cross-language Noise IK handshake vectors.
//
// These exact hex strings are also asserted in
// `speed-server/crypto/noise_cross_test.go`. Every other implementation
// (Dart, Go, eventually Swift) MUST produce the same bytes byte for
// byte. If one of them diverges, the protocol has drifted — that's a
// release-blocking bug.
//
// Inputs:
//   initiator static seed:   0x01 followed by 31 zero bytes
//   initiator ephemeral:     0x02 followed by 31 zero bytes
//   responder static seed:   0x03 followed by 31 zero bytes
//   responder ephemeral:     0x04 followed by 31 zero bytes
//   message1 payload:        "hello server"
//   message2 payload:        "hello client"

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/crypto/noise.dart';
import 'package:arcane_dispatch/crypto/seal.dart';

const String crossInitStaticSeed =
    '0100000000000000000000000000000000000000000000000000000000000000';
const String crossInitEphSeed =
    '0200000000000000000000000000000000000000000000000000000000000000';
const String crossRespStaticSeed =
    '0300000000000000000000000000000000000000000000000000000000000000';
const String crossRespEphSeed =
    '0400000000000000000000000000000000000000000000000000000000000000';
const String crossMsg1PayloadHex = '68656c6c6f20736572766572'; // "hello server"
const String crossMsg2PayloadHex = '68656c6c6f20636c69656e74'; // "hello client"

// Locked wire vectors captured from the canonical Go output. Mirror of
// `expectedMsg1Hex` etc. in noise_cross_test.go.
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
  test('Noise IK + sealed-frame matches Go-captured wire bytes', () async {
    NoiseKeypair initStatic =
        await NoiseKeypair.fromSeed(_seedFromHex(crossInitStaticSeed));
    NoiseKeypair respStatic =
        await NoiseKeypair.fromSeed(_seedFromHex(crossRespStaticSeed));

    HandshakeState init = await HandshakeState.initiator(
      s: initStatic,
      rs: respStatic.public,
    );
    await init.setTestEphemeral(_seedFromHex(crossInitEphSeed));

    HandshakeState resp = await HandshakeState.responder(s: respStatic);
    await resp.setTestEphemeral(_seedFromHex(crossRespEphSeed));

    Uint8List msg1 =
        await init.writeMessage1(_hexToBytes(crossMsg1PayloadHex));
    expect(_bytesToHex(msg1), expectedMsg1Hex,
        reason: 'message1 wire bytes drifted from Go canonical output');

    Uint8List recv1 = await resp.readMessage1(msg1);
    expect(_bytesToHex(recv1), crossMsg1PayloadHex);

    var resp2 =
        await resp.writeMessage2(_hexToBytes(crossMsg2PayloadHex));
    expect(_bytesToHex(resp2.msg), expectedMsg2Hex,
        reason: 'message2 wire bytes drifted from Go canonical output');

    var initRead = await init.readMessage2(resp2.msg);
    expect(_bytesToHex(initRead.payload), crossMsg2PayloadHex);

    // Transport keys must match Go-captured values exactly.
    expect(_bytesToHex(initRead.transport.sendKey), expectedInitSendKeyHex,
        reason: 'initiator sendKey drifted from Go canonical');
    expect(_bytesToHex(initRead.transport.recvKey), expectedInitRecvKeyHex,
        reason: 'initiator recvKey drifted from Go canonical');

    // Responder transport is the mirror image.
    expect(_bytesToHex(resp2.transport.recvKey),
        _bytesToHex(initRead.transport.sendKey));
    expect(_bytesToHex(resp2.transport.sendKey),
        _bytesToHex(initRead.transport.recvKey));

    // First sealed frame from the initiator must match Go's bytes.
    Uint8List wire = await seal(
      initRead.transport,
      Uint8List.fromList('hello'.codeUnits),
    );
    expect(_bytesToHex(wire), expectedFirstSealedHex,
        reason: 'first sealed frame drifted from Go canonical');

    // And opening it on the responder yields the original plaintext.
    SealedHeader hdr = decodeSealedHeader(
        Uint8List.sublistView(wire, 0, sealedHeaderSize));
    Uint8List plain = await openSealed(
      resp2.transport,
      hdr,
      Uint8List.sublistView(wire, sealedHeaderSize),
    );
    expect(String.fromCharCodes(plain), 'hello');
  });
}
