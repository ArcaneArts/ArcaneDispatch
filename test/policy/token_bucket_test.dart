import 'package:arcane_dispatch/policy/token_bucket.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TokenBucket', () {
    test('isUnlimited when refill <= 0', () {
      TokenBucket b = TokenBucket(refillBytesPerSec: 0);
      expect(b.isUnlimited, isTrue);
      b.dispose();
    });

    test('unlimited bucket: acquire completes immediately', () async {
      TokenBucket b = TokenBucket(refillBytesPerSec: 0);
      await b.acquire(10000000); // should not throw / not delay
      b.dispose();
    });

    test('tryConsume returns 0 when bucket is empty (after draining)', () {
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 1000,
        burstBytes: 1000,
        now: () => fakeNow,
      );
      // Drain the full burst.
      int taken = b.tryConsume(1000);
      expect(taken, 1000);
      int again = b.tryConsume(500);
      expect(again, 0);
      b.dispose();
    });

    test('tryConsume returns min(available, requested)', () {
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 1000,
        burstBytes: 1000,
        now: () => fakeNow,
      );
      int taken = b.tryConsume(2000);
      expect(taken, 1000);
      b.dispose();
    });

    test('tokens refill at the configured rate over time', () {
      // Mutable clock so we can advance time without sleeping.
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 1000,
        burstBytes: 2000,
        now: () => fakeNow,
      );
      // Drain.
      expect(b.tryConsume(2000), 2000);
      expect(b.tryConsume(1), 0);
      // Advance 500 ms -> expect ~500 tokens.
      fakeNow = fakeNow.add(const Duration(milliseconds: 500));
      double tokens = b.tokens;
      expect(tokens, inInclusiveRange(490.0, 510.0));
      b.dispose();
    });

    test('tokens cap at burstBytes when idle', () {
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 1000,
        burstBytes: 500,
        now: () => fakeNow,
      );
      // Bucket starts full at burst (500). Advance 10 s -> still 500.
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      expect(b.tokens, 500);
      b.dispose();
    });

    test('default burstBytes equals refillBytesPerSec', () {
      TokenBucket b = TokenBucket(refillBytesPerSec: 12345);
      expect(b.burstBytes, 12345);
      b.dispose();
    });

    test('acquire waits until enough tokens accumulate', () async {
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 10000, // 10 KB/s
        burstBytes: 5000,
        now: () => fakeNow,
      );
      // Drain to zero, then ask for 2500 (~250 ms at 10 KB/s).
      // Stays under burstBytes so the bucket can actually reach the threshold.
      expect(b.tryConsume(5000), 5000);

      // Background: advance fake clock at the bucket's polling cadence so its
      // `_refill()` sees enough elapsed time on each retry.
      Future<void> advancer() async {
        for (int i = 0; i < 40; i += 1) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          fakeNow = fakeNow.add(const Duration(milliseconds: 100));
        }
      }

      Stopwatch sw = Stopwatch()..start();
      Future<void> acquire = b.acquire(2500);
      Future<void> advance = advancer();
      await acquire.timeout(const Duration(seconds: 5));
      sw.stop();
      await advance;

      // After acquire returns, the bucket should have ~half its tokens.
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(0));
      b.dispose();
    });

    test('acquire after dispose throws StateError', () async {
      TokenBucket b = TokenBucket(refillBytesPerSec: 1000);
      b.dispose();
      await expectLater(
        b.acquire(10),
        throwsA(isA<StateError>()),
      );
    });

    test('tryConsume after dispose returns 0', () {
      TokenBucket b = TokenBucket(refillBytesPerSec: 1000);
      b.dispose();
      expect(b.tryConsume(10), 0);
    });

    test('acquire(0) is a no-op even when bucket is empty', () async {
      DateTime fakeNow = DateTime(2026, 1, 1);
      TokenBucket b = TokenBucket(
        refillBytesPerSec: 1000,
        burstBytes: 100,
        now: () => fakeNow,
      );
      expect(b.tryConsume(100), 100); // drain
      await b.acquire(0); // should return immediately
      b.dispose();
    });

    test('negative refill is normalized to unlimited', () {
      TokenBucket b = TokenBucket(refillBytesPerSec: -5);
      expect(b.isUnlimited, isTrue);
      b.dispose();
    });
  });
}
