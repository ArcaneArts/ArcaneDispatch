// Unit tests for the Dart anti-replay window.
//
// Behaviour parity with `speed-server/crypto/replay_test.go` is enforced
// by re-running the same scenarios here. Drift = bug.

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/crypto/replay.dart';

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
      // A nonce near the new high water mark is still accepted.
      w.check(999999);
    });

    test('size <= 0 falls back to default window', () {
      ReplayWindow w = ReplayWindow(size: -1);
      expect(w.size, defaultReplayWindow);
    });
  });
}
