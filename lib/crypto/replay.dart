/// Anti-replay sliding window (Dart side).
///
/// Mirror of `speed-server/crypto/replay.go`. See that file for the
/// construction (RFC 4303-style sliding bitmap).
library;

/// Default window size — 1024 entries, per the Phase 9 spec.
const int defaultReplayWindow = 1024;

/// Thrown when a nonce has already been seen.
class ReplayDetectedException implements Exception {
  final int nonce;
  ReplayDetectedException(this.nonce);
  @override
  String toString() => 'crypto: replay detected (nonce=$nonce)';
}

/// Thrown when a nonce predates the window's left edge.
class NonceTooOldException implements Exception {
  final int nonce;
  final int windowStart;
  NonceTooOldException(this.nonce, this.windowStart);
  @override
  String toString() =>
      'crypto: nonce $nonce predates window (start=$windowStart)';
}

/// Tracks the highest nonce seen plus a bitmap of the last [size] nonces.
class ReplayWindow {
  final int size;
  int _highest = 0;
  bool _primed = false;
  late final List<int> _bitmap; // each int covers 64 bits

  ReplayWindow({int size = defaultReplayWindow})
    : size = size > 0 ? size : defaultReplayWindow {
    int words = (this.size + 63) ~/ 64;
    _bitmap = List<int>.filled(words, 0);
  }

  /// Inspect [nonce]. First call always succeeds. Throws on replay or
  /// too-old; returns normally on accept.
  void check(int nonce) {
    if (!_primed) {
      _primed = true;
      _highest = nonce;
      _setBit(0);
      return;
    }
    if (nonce > _highest) {
      int shift = nonce - _highest;
      _shiftLeft(shift);
      _highest = nonce;
      _setBit(0);
      return;
    }
    int offset = _highest - nonce;
    if (offset >= size) {
      throw NonceTooOldException(nonce, _highest - size + 1);
    }
    if (_testBit(offset)) {
      throw ReplayDetectedException(nonce);
    }
    _setBit(offset);
  }

  /// Highest nonce ever accepted; 0 before the first call.
  int get highest => _highest;

  void _shiftLeft(int by) {
    if (by >= size) {
      for (int i = 0; i < _bitmap.length; i++) {
        _bitmap[i] = 0;
      }
      return;
    }
    int bigShift = by ~/ 64;
    int smallShift = by % 64;
    if (bigShift > 0) {
      for (int i = _bitmap.length - 1; i >= 0; i--) {
        int src = i - bigShift;
        if (src < 0) {
          _bitmap[i] = 0;
        } else {
          _bitmap[i] = _bitmap[src];
        }
      }
    }
    if (smallShift > 0) {
      int carry = 0;
      for (int i = 0; i < _bitmap.length; i++) {
        int newCarry = (smallShift == 0)
            ? 0
            : (_bitmap[i] >>> (64 - smallShift));
        _bitmap[i] = ((_bitmap[i] << smallShift) | carry) & _u64Mask;
        carry = newCarry;
      }
    }
  }

  void _setBit(int i) {
    if (i >= size) return;
    _bitmap[i ~/ 64] |= 1 << (i % 64);
  }

  bool _testBit(int i) {
    if (i >= size) return false;
    return (_bitmap[i ~/ 64] & (1 << (i % 64))) != 0;
  }
}

const int _u64Mask = 0xFFFFFFFFFFFFFFFF;
