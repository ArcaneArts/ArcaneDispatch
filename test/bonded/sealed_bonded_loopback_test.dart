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

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/bonded/local_bonded_loopback.dart';

Uint8List _xorTransform(Uint8List src) {
  Uint8List out = Uint8List(src.length);
  for (int i = 0; i < src.length; i++) {
    out[i] = src[i] ^ 0xAA;
  }
  return out;
}

void main() {
  test('sealed bonded loopback round-trips through reversible transform',
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

    Uint8List payload =
        Uint8List.fromList(List<int>.generate(8 * 1024, (int i) => i & 0xFF));
    int sent = loopback.client.send(payload);
    expect(sent, payload.length);
    await loopback.waitForServerBytes(payload.length,
        timeout: const Duration(seconds: 4));
    expect(joinReceived(loopback.serverReceived), payload,
        reason: 'sealer/opener pair must round-trip every byte');
    await loopback.dispose();
  });

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
    expect(loopback.serverReceived, isEmpty,
        reason: 'a missing opener must drop the bytes silently');
    await loopback.dispose();
  });
}
