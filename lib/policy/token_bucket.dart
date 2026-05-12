import 'dart:async';
import 'dart:math' as math;

/// Leaky-bucket / token-bucket throttle for per-link byte-rate caps.
///
/// One bucket per [Link]. Tokens represent bytes; the bucket refills at
/// [refillBytesPerSec] and can never exceed [burstBytes]. A consumer asks for
/// `n` bytes by calling [acquire]; if there aren't enough tokens, the future
/// completes once enough have accumulated.
///
/// Why this matters: the SOCKS pipe loop (`lib/core/socks_proxy_server.dart:347-369`)
/// proxies chunks of bytes between two sockets. Wrapping each chunk in
/// `bucket.acquire(chunk.length)` makes the proxy honor a per-link Mbps cap
/// without changing the rest of the pipeline. Phase 7's bonded transport reuses
/// the same primitive at the packet boundary.
///
/// Design notes:
/// * Time source is injectable so unit tests can advance a fake clock without
///   sleeping. In production we use [DateTime.now] via the default
///   [_systemNow].
/// * `acquire` is reentrant-safe but not FIFO across concurrent callers;
///   simultaneous callers are served as fast as tokens drip in. For the SOCKS
///   pipe (single producer per direction) this is good enough; if we ever need
///   fairness we'll switch to a queue.
/// * `dispose` cancels any pending refill timer so the bucket can be GC'd
///   without leaking a periodic Timer.
class TokenBucket {
  /// Refill rate in bytes per second. `0` => unlimited (every [acquire] is
  /// immediate and consumes nothing). Negative values are normalized to 0.
  final int refillBytesPerSec;

  /// Maximum bucket capacity in bytes. Defaults to one second of refill so a
  /// link with a 5 Mbps cap can absorb a 5 Mbit burst before throttling kicks
  /// in. Set to a higher value to allow burstier traffic.
  final int burstBytes;

  final DateTime Function() _now;
  double _tokens;
  DateTime _lastRefill;
  bool _disposed = false;

  TokenBucket({
    required this.refillBytesPerSec,
    int? burstBytes,
    DateTime Function() now = _systemNow,
  })  : burstBytes = burstBytes ?? math.max(refillBytesPerSec, 0),
        _now = now,
        _lastRefill = now(),
        _tokens = (burstBytes ?? math.max(refillBytesPerSec, 0)).toDouble();

  /// True when the cap is "unlimited" (refill = 0). Callers can short-circuit
  /// in this case to avoid the async wait entirely.
  bool get isUnlimited {
    return refillBytesPerSec <= 0;
  }

  /// Current token count after refilling against the wall clock. Exposed so
  /// tests can assert that refills happen as expected.
  double get tokens {
    _refill();
    return _tokens;
  }

  /// Synchronous attempt to consume [bytes]. Returns the number of bytes
  /// actually consumed (between 0 and [bytes]). Useful for the bonded
  /// scheduler which prefers to send less rather than wait.
  int tryConsume(int bytes) {
    if (_disposed || bytes <= 0) {
      return 0;
    }
    if (isUnlimited) {
      return bytes;
    }
    _refill();
    int available = _tokens.floor();
    if (available <= 0) {
      return 0;
    }
    int taken = math.min(available, bytes);
    _tokens -= taken.toDouble();
    return taken;
  }

  /// Wait until [bytes] worth of tokens are available, then consume them.
  ///
  /// Completes immediately when the bucket is unlimited or has enough tokens.
  /// Otherwise schedules a [Timer] for the remaining deficit and tries again.
  /// Throws [StateError] when called after [dispose].
  Future<void> acquire(int bytes) async {
    if (_disposed) {
      throw StateError('TokenBucket has been disposed.');
    }
    if (bytes <= 0 || isUnlimited) {
      return;
    }
    while (true) {
      if (_disposed) {
        throw StateError('TokenBucket has been disposed.');
      }
      _refill();
      if (_tokens >= bytes) {
        _tokens -= bytes.toDouble();
        return;
      }
      double deficit = bytes - _tokens;
      // How many seconds at the current refill rate it takes to gain `deficit`
      // tokens. Clamp to a minimum of 1 ms so we don't spin in tight loops on
      // round-off.
      double seconds = deficit / refillBytesPerSec;
      Duration wait = Duration(
        microseconds: math.max(1000, (seconds * 1e6).ceil()),
      );
      await Future<void>.delayed(wait);
    }
  }

  void dispose() {
    _disposed = true;
  }

  void _refill() {
    if (isUnlimited) {
      return;
    }
    DateTime now = _now();
    double elapsedSeconds =
        now.difference(_lastRefill).inMicroseconds / 1e6;
    if (elapsedSeconds <= 0) {
      return;
    }
    _tokens = math.min(
      burstBytes.toDouble(),
      _tokens + elapsedSeconds * refillBytesPerSec,
    );
    _lastRefill = now;
  }

  static DateTime _systemNow() {
    return DateTime.now();
  }
}
