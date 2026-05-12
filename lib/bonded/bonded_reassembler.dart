// Sliding-window reassembler for the bonded transport.
//
// The bonded scheduler stripes a single application stream across multiple
// underlying links, so packets arrive out of order. This module:
//
//   * Buffers packets in [seq] order.
//   * Emits payloads contiguously (in seq order) via [BondedReassembler.outbound].
//   * Runs a gap timer: if a hole in the sequence stays unfilled past
//     [gapTimeout] from the last delivery, we emit a NAK request via
//     [BondedReassembler.nakRequests] so the caller can ask the peer to
//     retransmit.
//   * Drops packets that fall behind [windowSize] (too old to matter) to
//     prevent unbounded memory growth.
//
// Mirrored on the Swift side by
// `macos/ArcaneDispatchTunnel/Bonded/BondedReassembler.swift`. Keep the
// emit / NAK semantics in sync; the on-wire NAK format itself is defined in
// `bonded_framing.dart`.

import 'dart:async';
import 'dart:typed_data';

/// Range of contiguous seq numbers the receiver hasn't seen yet. Inclusive
/// on both ends: `[startSeq, endSeq]`. Emitted to [BondedReassembler.nakRequests]
/// when a gap stays open past the gap timeout.
class BondedNakRange {
  final int startSeq;
  final int endSeq;
  const BondedNakRange(this.startSeq, this.endSeq);

  int get length => endSeq - startSeq + 1;

  @override
  String toString() => 'NAK[$startSeq..$endSeq]';
}

/// Statistics surfaced for the UI / diagnostics. Read-only snapshot.
class BondedReassemblerStats {
  /// Highest contiguous seq we have delivered to the caller.
  final int nextExpectedSeq;

  /// Total payloads emitted in order.
  final int delivered;

  /// Total payloads dropped because they fell outside the window.
  final int droppedStale;

  /// Total payloads dropped because they were duplicates of seqs we had
  /// already delivered.
  final int droppedDuplicate;

  /// Total NAK ranges raised.
  final int naks;

  /// Bytes currently pending in the out-of-order buffer.
  final int bufferedBytes;

  /// Number of seqs sitting in the out-of-order buffer.
  final int bufferedCount;

  const BondedReassemblerStats({
    required this.nextExpectedSeq,
    required this.delivered,
    required this.droppedStale,
    required this.droppedDuplicate,
    required this.naks,
    required this.bufferedBytes,
    required this.bufferedCount,
  });
}

/// Re-orders payloads from the per-link UDP receive paths into a single
/// in-order byte stream. Single-producer (the bonded session's per-link
/// receive callback), single-consumer (the tunnel write side).
///
/// Not thread-safe — Dart isolates are cheap, but inside one isolate we
/// rely on the event-loop's single-threaded model. The Swift port uses a
/// serial DispatchQueue for the same reason.
class BondedReassembler {
  /// First seq that has not yet been emitted. Starts at 0 (matches the
  /// sender's monotonic counter from `bonded_framing.dart`).
  int _nextSeq;

  /// Out-of-order buffer keyed by seq. Holds payloads we received but
  /// haven't been able to deliver yet because of an earlier gap.
  final Map<int, Uint8List> _buffer = <int, Uint8List>{};

  /// Time the earliest hole was first observed. Used to compute when to
  /// emit a NAK. `null` when there's no gap.
  DateTime? _gapSince;

  /// Window of acceptable seqs ahead of [_nextSeq]. Anything farther ahead
  /// is dropped as malicious / corrupted.
  final int windowSize;

  /// How long a hole may stay open before we emit a NAK request. Speedify
  /// uses something close to 2× max(RTT); the bonded session picks this
  /// dynamically from the per-link probe and forwards into the reassembler.
  Duration gapTimeout;

  /// Hard wall on memory the buffer can hold. Prevents OOM when an attacker
  /// floods us with high-seq payloads that we can never deliver.
  final int maxBufferedBytes;

  // Statistics counters.
  int _delivered = 0;
  int _droppedStale = 0;
  int _droppedDuplicate = 0;
  int _naks = 0;

  final StreamController<Uint8List> _outbound;
  final StreamController<BondedNakRange> _nakRequests;
  Timer? _gapTimer;
  bool _disposed = false;

  BondedReassembler({
    int initialNextSeq = 0,
    this.windowSize = 4096,
    this.gapTimeout = const Duration(milliseconds: 100),
    this.maxBufferedBytes = 4 * 1024 * 1024, // 4 MiB
  })  : _nextSeq = initialNextSeq,
        _outbound = StreamController<Uint8List>.broadcast(),
        _nakRequests = StreamController<BondedNakRange>.broadcast() {
    assert(windowSize > 0);
    assert(maxBufferedBytes > 0);
  }

  /// Stream of in-order payload chunks. Subscribe before pushing the first
  /// packet — broadcast events that arrive without a listener are dropped.
  Stream<Uint8List> get outbound => _outbound.stream;

  /// Stream of NAK requests the bonded session must turn into wire frames
  /// and send back to the peer.
  Stream<BondedNakRange> get nakRequests => _nakRequests.stream;

  /// True once [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Snapshot of internal counters. Cheap; called from the UI tick.
  BondedReassemblerStats snapshot() {
    int bufferedBytes = 0;
    for (Uint8List buf in _buffer.values) {
      bufferedBytes += buf.length;
    }
    return BondedReassemblerStats(
      nextExpectedSeq: _nextSeq,
      delivered: _delivered,
      droppedStale: _droppedStale,
      droppedDuplicate: _droppedDuplicate,
      naks: _naks,
      bufferedBytes: bufferedBytes,
      bufferedCount: _buffer.length,
    );
  }

  /// Feed a freshly-decoded payload into the reassembler. The caller is
  /// expected to have already validated the wire frame.
  void onPayload({required int seq, required Uint8List payload}) {
    if (_disposed) {
      return;
    }
    if (seq < _nextSeq) {
      // Already delivered; could be the peer retransmitting after a stale
      // NAK or a network duplicate. Either way we don't want it.
      _droppedDuplicate++;
      return;
    }
    if (seq >= _nextSeq + windowSize) {
      // Way ahead of the window — refuse to buffer it. Could be an attacker
      // trying to OOM us, or a vastly out-of-spec sender. We don't NAK
      // because we'd be NAKing every seq between here and there.
      _droppedStale++;
      return;
    }
    if (seq == _nextSeq) {
      _emit(seq, payload);
      _drainBuffer();
      _updateGapState();
      return;
    }
    // Hole exists; buffer the payload. If a slot is already taken by a
    // duplicate, prefer the first one (don't reset gap state mid-flight).
    if (_buffer.containsKey(seq)) {
      _droppedDuplicate++;
      return;
    }
    if (_bufferedBytes() + payload.length > maxBufferedBytes) {
      // We hit the OOM guard. Drop the highest-seq buffered payload to make
      // room — if we drop the new one we could miss legit data; if we drop
      // a buffered one the NAK loop will re-fetch it.
      _evictHighest();
    }
    _buffer[seq] = payload;
    _updateGapState();
  }

  /// Called by the session driver when the peer signals an explicit close
  /// (or when the session is being torn down). Empties internal state and
  /// closes the output stream so the consumer can flush.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _gapTimer?.cancel();
    _gapTimer = null;
    _buffer.clear();
    await _outbound.close();
    await _nakRequests.close();
  }

  // ---------------------------------------------------------------------
  // internals
  // ---------------------------------------------------------------------

  void _emit(int seq, Uint8List payload) {
    _outbound.add(payload);
    _nextSeq = seq + 1;
    _delivered++;
  }

  /// Walk forward through `_buffer` emitting any contiguous seqs that
  /// follow `_nextSeq`. Stops at the first gap.
  void _drainBuffer() {
    while (_buffer.containsKey(_nextSeq)) {
      Uint8List payload = _buffer.remove(_nextSeq)!;
      _emit(_nextSeq, payload);
    }
  }

  void _updateGapState() {
    bool hasGap = _buffer.isNotEmpty;
    if (!hasGap) {
      _gapSince = null;
      _gapTimer?.cancel();
      _gapTimer = null;
      return;
    }
    _gapSince ??= DateTime.now();
    _gapTimer ??= Timer(gapTimeout, _onGapTimeout);
  }

  void _onGapTimeout() {
    _gapTimer = null;
    if (_disposed) return;
    if (_buffer.isEmpty) {
      _gapSince = null;
      return;
    }
    // Build a NAK range covering the contiguous missing seqs between
    // _nextSeq and the lowest buffered seq − 1. We only NAK the *first* hole
    // each tick; on the peer's reply we'll discover whether further NAKs
    // are needed.
    int lowestBuffered = _buffer.keys.fold<int>(0x7fffffffffffffff,
        (int acc, int seq) => seq < acc ? seq : acc);
    int gapEnd = lowestBuffered - 1;
    BondedNakRange range = BondedNakRange(_nextSeq, gapEnd);
    _naks++;
    _nakRequests.add(range);

    // Reset the gap timer so the next NAK only fires after another
    // gapTimeout interval if the hole still isn't filled.
    _gapSince = DateTime.now();
    _gapTimer = Timer(gapTimeout, _onGapTimeout);
  }

  int _bufferedBytes() {
    int total = 0;
    for (Uint8List p in _buffer.values) {
      total += p.length;
    }
    return total;
  }

  void _evictHighest() {
    if (_buffer.isEmpty) return;
    int highest = _buffer.keys.fold<int>(_nextSeq,
        (int acc, int seq) => seq > acc ? seq : acc);
    _buffer.remove(highest);
    _droppedStale++;
  }
}
