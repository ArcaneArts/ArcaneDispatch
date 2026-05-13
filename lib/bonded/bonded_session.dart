// Bonded session orchestrator.
//
// Sits between the application's byte stream (incoming Uint8List from the
// tunnel or the local SOCKS server) and the per-link UDP send/receive
// callbacks. Holds:
//   * [BondedScheduler] — picks which link each outbound chunk goes on.
//   * [BondedReassembler] — re-orders inbound chunks back into seq order.
//   * Keepalive timer — fires per link at a configurable cadence so the
//     scheduler's RTT/credit estimates stay fresh during idle.
//   * NAK retransmission — when the peer sends a NAK we resend from a small
//     cache of recently-sent payloads (the "retransmit buffer").
//
// The session is single-isolate and event-loop driven. The Swift mirror
// will use a serial DispatchQueue to enforce the same invariants.
//
// Lifecycle: build once per (sessionId, localPolicy). Call [start] to spin
// up keepalives, push outbound bytes with [send], surface inbound payloads
// with [onInboundFrame], and tear down with [dispose].

import 'dart:async';
import 'dart:typed_data';

import '../core/bonding_mode.dart';
import '../core/link.dart';
import 'bonded_framing.dart';
import 'bonded_modes.dart';
import 'bonded_reassembler.dart';
import 'bonded_scheduler.dart';

/// Function the session calls when it has a fully-encoded frame ready to
/// hit the wire on a specific link. The caller (typically a UDP socket
/// wrapper) is expected to push the bytes onto its link asynchronously.
typedef BondedSendOnLink = void Function(String linkId, Uint8List bytes);

/// Optional hook fired on every outbound pick. Used by the controller for
/// telemetry / flow-inspector accounting. Cheap; runs synchronously.
typedef BondedDecisionObserver = void Function(BondedSchedulingDecision d);

/// Optional transform applied to every outbound frame *after* framing but
/// *before* `sendOnLink`. The canonical use case is wrapping the frame in
/// a Noise sealed envelope (`lib/crypto/seal.dart::seal`). Must be cheap
/// and synchronous — heavy crypto belongs on a background isolate, with
/// the result pushed into this callback when ready.
typedef BondedFrameSealer = Uint8List Function(Uint8List rawFrame);

/// Optional transform applied to every inbound wire blob *before* framing
/// is decoded. Returning `null` means the caller should drop the bytes
/// silently (e.g. unseal AEAD failure / replay rejection).
typedef BondedFrameOpener = Uint8List? Function(Uint8List wireBytes);

/// Configuration for a bonded session. All fields are tunables; the
/// defaults match the spec in the master plan.
class BondedSessionConfig {
  /// 64-bit session identifier stamped into every outbound frame. Pick a
  /// random u64 on the client; the server checks it for routing.
  final int sessionId;

  /// Initial bonding mode for this session. The mode is mutable at
  /// runtime via [BondedSession.setMode].
  final BondingMode mode;

  /// How often each link sends a keepalive when there's no outbound
  /// traffic. 5 Hz (200 ms) matches the spec.
  final Duration keepaliveInterval;

  /// Gap timeout passed through to the reassembler.
  final Duration reassemblerGapTimeout;

  /// Sliding-window size passed through to the reassembler.
  final int reassemblerWindowSize;

  /// Max payload bytes per outbound frame. The session splits larger
  /// writes into multiple frames.
  final int maxPayload;

  /// Size of the retransmit cache. Capped to keep memory in check; on a
  /// 100 Mbps link with 200 ms RTT that's ~2.5 MB of inflight bytes —
  /// the default 256 entries × 1208 B = 309 KB easily covers that.
  final int retransmitBufferSize;

  const BondedSessionConfig({
    required this.sessionId,
    this.mode = BondingMode.speed,
    this.keepaliveInterval = const Duration(milliseconds: 200),
    this.reassemblerGapTimeout = const Duration(milliseconds: 100),
    this.reassemblerWindowSize = 4096,
    this.maxPayload = kBondedMaxPayload,
    this.retransmitBufferSize = 256,
  });
}

/// Snapshot of all per-session counters. Useful for the UI tick and for
/// debugging starvation issues.
class BondedSessionStats {
  /// Highest outbound seq we've sent.
  final int lastSentSeq;

  /// Whatever the reassembler reports for inbound progress.
  final BondedReassemblerStats inbound;

  /// Outbound payloads we sent on each link.
  final Map<String, int> packetsPerLink;

  /// Outbound bytes we sent on each link.
  final Map<String, int> bytesPerLink;

  /// Outbound retransmissions sent.
  final int retransmissions;

  /// Keepalives sent.
  final int keepalives;

  /// Chunks where the active mode fanned out the same seq to multiple links.
  final int duplicateFanouts;

  /// Currently-active bonding mode.
  final BondingMode mode;

  const BondedSessionStats({
    required this.lastSentSeq,
    required this.inbound,
    required this.packetsPerLink,
    required this.bytesPerLink,
    required this.retransmissions,
    required this.keepalives,
    required this.duplicateFanouts,
    required this.mode,
  });
}

/// The orchestrator. See module header for design notes.
class BondedSession {
  final BondedSessionConfig config;
  final BondedScheduler scheduler;
  final BondedReassembler reassembler;
  final BondedSendOnLink sendOnLink;
  final BondedDecisionObserver? observer;

  /// Active mode strategy. Mutable via [setMode]; defaults to whatever
  /// [BondedSessionConfig.mode] said at construction.
  BondedModeStrategy _strategy;

  /// Optional outbound transform applied right before `sendOnLink`.
  /// Typical wiring: `(frame) => seal(noiseTransport, frame)`.
  final BondedFrameSealer? sealer;

  /// Optional inbound transform applied to wire bytes before decode.
  /// Typical wiring: `(buf) => openSealed(transport, header, body)`.
  final BondedFrameOpener? opener;

  /// Monotonic outbound seq counter. The first packet is seq=0 to keep the
  /// invariant simple with the reassembler.
  int _nextSeq = 0;

  /// Retransmit cache: insertion-ordered map of `seq → (linkId, payload)`.
  /// We pop the oldest entry once the cache exceeds `retransmitBufferSize`.
  final Map<int, _RetransmitEntry> _retransmitCache = <int, _RetransmitEntry>{};

  /// Per-link keepalive timers.
  final Map<String, Timer> _keepaliveTimers = <String, Timer>{};

  /// Per-link counters for telemetry.
  final Map<String, int> _packetsPerLink = <String, int>{};
  final Map<String, int> _bytesPerLink = <String, int>{};
  int _retransmissions = 0;
  int _keepalives = 0;
  int _duplicateFanouts = 0;

  StreamSubscription<BondedNakRange>? _nakSub;
  bool _started = false;
  bool _disposed = false;

  BondedSession({
    required this.config,
    required this.sendOnLink,
    BondedScheduler? scheduler,
    BondedReassembler? reassembler,
    BondedModeStrategy? strategy,
    this.observer,
    this.sealer,
    this.opener,
  }) : scheduler = scheduler ?? BondedScheduler(),
       reassembler =
           reassembler ??
           BondedReassembler(
             gapTimeout: config.reassemblerGapTimeout,
             windowSize: config.reassemblerWindowSize,
           ),
       _strategy = strategy ?? BondedModeStrategy.forMode(config.mode);

  /// Currently-active mode strategy.
  BondedModeStrategy get strategy => _strategy;

  /// Switch the bonding mode at runtime. Cheap — the existing scheduler,
  /// reassembler, retransmit cache, and seq counter all carry over so
  /// in-flight TCP streams are not disturbed.
  void setMode(BondingMode mode) {
    if (_strategy.mode == mode) return;
    _strategy = BondedModeStrategy.forMode(mode);
  }

  /// Wire up internal subscriptions and start per-link keepalives.
  void start() {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    // When our reassembler spots a gap, encode the missing range as a NAK
    // frame and send it back to the peer over the fastest link. The peer's
    // session handles `_handlePeerNak` and retransmits from its own
    // retransmit cache. Local handling here would be wrong: only the
    // ORIGINAL sender has the bytes.
    _nakSub = reassembler.nakRequests.listen(_sendNakToPeer);
    _restartKeepalives();
  }

  /// Push policy/metric updates into the scheduler. Also re-syncs the
  /// keepalive timers to the new link set.
  void updateLinks(Iterable<BondedLinkState> links) {
    scheduler.updateLinks(links);
    if (_started) {
      _restartKeepalives();
    }
  }

  /// Send [bytes] over the bond. Splits into ≤ [BondedSessionConfig.maxPayload]
  /// chunks; returns the number of bytes scheduled (could be less than the
  /// input if some chunks had no eligible link).
  int send(Uint8List bytes) {
    if (_disposed || !_started || bytes.isEmpty) {
      return 0;
    }
    int sent = 0;
    int offset = 0;
    while (offset < bytes.length) {
      int chunkLen = bytes.length - offset;
      if (chunkLen > config.maxPayload) {
        chunkLen = config.maxPayload;
      }
      Uint8List chunk = Uint8List.sublistView(bytes, offset, offset + chunkLen);
      bool ok = _sendOne(chunk);
      if (!ok) {
        // No eligible link — stop, caller can retry once a link comes back.
        break;
      }
      offset += chunkLen;
      sent += chunkLen;
    }
    return sent;
  }

  /// Handle an inbound frame from any link. The framing layer hands us a
  /// decoded [BondedFrame]; this routes it to the reassembler (or to the
  /// keepalive / NAK paths).
  void onInboundFrame(BondedFrame frame) {
    if (_disposed) {
      return;
    }
    if (frame.sessionId != config.sessionId) {
      // Not for us — silently drop. Could be a stray packet from a
      // different bonded client on the same UDP port; we don't escalate.
      return;
    }
    if (frame.isKeepalive) {
      // Peer keepalive — no application data, but we use it as a signal to
      // the scheduler/probe layer. Body is the peer's inflight counter
      // (u64 LE) which we currently ignore in v0.
      return;
    }
    if (frame.isAck) {
      // Bookkeeping: free the bytes from the scheduler's inflight counter
      // for the link the packet came back on.
      scheduler.completeSend(
        _linkIdForWireId(frame.linkId),
        frame.payload.length,
      );
      return;
    }
    if (frame.isNak) {
      // Peer is asking for retransmits; payload is little-endian u64
      // pairs of (startSeq, endSeq). v0 supports one range per frame.
      _handlePeerNak(frame.payload);
      return;
    }
    reassembler.onPayload(seq: frame.seq, payload: frame.payload);
  }

  /// Handle a fresh blob of wire bytes from any link. Unseals (if an
  /// [opener] is wired), decodes the bonded frame, then dispatches via
  /// [onInboundFrame]. Returns `true` if the bytes were accepted, `false`
  /// if they were dropped (unseal failure, malformed framing, etc.).
  ///
  /// Use this entry point from the link receiver when sealing is in play;
  /// transports that already decode frames themselves (e.g. legacy unit
  /// tests) can keep calling [onInboundFrame].
  bool onInboundBytes(Uint8List wireBytes) {
    if (_disposed) {
      return false;
    }
    Uint8List? plain = _openIfEnabled(wireBytes);
    if (plain == null) {
      // Unseal rejected the bytes (replay / AEAD failure / short blob).
      // No telemetry yet — we'll wire a "rejected" counter in Phase 15.
      return false;
    }
    try {
      BondedFrame frame = decodeBondedFrame(plain);
      onInboundFrame(frame);
      return true;
    } on BondedFramingException {
      // Same shape as a real wire drop.
      return false;
    }
  }

  /// Snapshot for the UI / debugging.
  BondedSessionStats snapshot() {
    return BondedSessionStats(
      lastSentSeq: _nextSeq == 0 ? 0 : _nextSeq - 1,
      inbound: reassembler.snapshot(),
      packetsPerLink: Map<String, int>.unmodifiable(_packetsPerLink),
      bytesPerLink: Map<String, int>.unmodifiable(_bytesPerLink),
      retransmissions: _retransmissions,
      keepalives: _keepalives,
      duplicateFanouts: _duplicateFanouts,
      mode: _strategy.mode,
    );
  }

  /// Tear down. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (Timer t in _keepaliveTimers.values) {
      t.cancel();
    }
    _keepaliveTimers.clear();
    await _nakSub?.cancel();
    _nakSub = null;
    await reassembler.dispose();
  }

  // ---------------------------------------------------------------------
  // internals
  // ---------------------------------------------------------------------

  bool _sendOne(Uint8List chunk) {
    BondedChunkPlan plan = _strategy.planChunk(
      bytes: chunk.length,
      scheduler: scheduler,
    );
    if (plan.isEmpty) {
      return false;
    }
    // All copies in this fan-out share the same seq so the receiver
    // dedupes naturally via the reassembler.
    int seq = _nextSeq;
    _nextSeq++;
    BondedSendPlan first = plan.sends.first;
    // The retransmit cache stores the *primary* link choice; if the
    // peer NAKs we'll reroute via a fresh scheduler.pickLink anyway.
    _retransmitCache[seq] = _RetransmitEntry(first.linkId, chunk);
    _trimRetransmitCache();

    for (BondedSendPlan d in plan.sends) {
      Uint8List frame = encodeBondedFrame(
        sessionId: config.sessionId,
        seq: seq,
        linkId: d.wireId,
        payload: chunk,
      );
      sendOnLink(d.linkId, _sealIfEnabled(frame));
      _packetsPerLink.update(d.linkId, (int v) => v + 1, ifAbsent: () => 1);
      _bytesPerLink.update(
        d.linkId,
        (int v) => v + chunk.length,
        ifAbsent: () => chunk.length,
      );
      observer?.call(d);
    }
    if (plan.fanout > 1) {
      _duplicateFanouts++;
    }
    return true;
  }

  void _trimRetransmitCache() {
    while (_retransmitCache.length > config.retransmitBufferSize) {
      int oldestSeq = _retransmitCache.keys.first;
      _retransmitCache.remove(oldestSeq);
    }
  }

  /// Encode a NAK range as a control frame and ship it on the best healthy
  /// link. Called from the reassembler's gap detector when a hole has stayed
  /// open past `gapTimeout`. The peer's session sees the frame, recognises
  /// the NAK flag, decodes the seq range, and retransmits from its own
  /// retransmit cache via [_retransmitRange].
  ///
  /// We pick the lowest-RTT healthy link manually (rather than calling
  /// `scheduler.pickLink`) to avoid polluting the inflight counters with a
  /// 16-byte control payload — bond accounting should reflect application
  /// bytes only.
  void _sendNakToPeer(BondedNakRange range) {
    if (_disposed) return;
    BondedLinkState? best = _bestHealthyLinkForControl();
    if (best == null) {
      // No healthy link to ship the NAK on; the next gap-timer tick will
      // retry. Without this guard we'd burn CPU encoding frames into the
      // void.
      return;
    }
    Uint8List payload = Uint8List(16);
    ByteData bd = ByteData.sublistView(payload);
    bd.setUint64(0, range.startSeq, Endian.big);
    bd.setUint64(8, range.endSeq, Endian.big);
    Uint8List frame = encodeBondedFrame(
      sessionId: config.sessionId,
      seq: 0, // control frame; receiver ignores the seq slot for NAKs
      linkId: best.wireId,
      flags: BondedFlags.nak,
      payload: payload,
    );
    sendOnLink(best.linkId, _sealIfEnabled(frame));
  }

  /// Find the lowest-RTT link in the best-priority bucket that's healthy.
  /// Used for shipping control frames (NAKs, future ACKs) without disturbing
  /// the credit/RR scheduler.
  BondedLinkState? _bestHealthyLinkForControl() {
    BondedLinkState? winner;
    double bestRtt = double.infinity;
    LinkPriority? bestBucket;
    for (BondedLinkState s in scheduler.states.values) {
      if (s.status == LinkStatus.unhealthy || s.status == LinkStatus.disabled) {
        continue;
      }
      if (s.priority == LinkPriority.never) {
        continue;
      }
      // Prefer primary over secondary over backup; inside a bucket, prefer
      // lowest RTT.
      if (bestBucket == null ||
          _priorityRank(s.priority) < _priorityRank(bestBucket)) {
        winner = s;
        bestBucket = s.priority;
        bestRtt = s.rttMs;
      } else if (s.priority == bestBucket && s.rttMs < bestRtt) {
        winner = s;
        bestRtt = s.rttMs;
      }
    }
    return winner;
  }

  int _priorityRank(LinkPriority p) {
    switch (p) {
      case LinkPriority.primary:
        return 0;
      case LinkPriority.secondary:
        return 1;
      case LinkPriority.backup:
        return 2;
      case LinkPriority.never:
        return 3;
    }
  }

  /// Re-send the seqs the peer asked for. Uses a *fresh* scheduling
  /// decision so the retransmit goes on the fastest currently-healthy link
  /// (not necessarily the same one the original took).
  void _retransmitRange(BondedNakRange range) {
    if (_disposed) return;
    for (int seq = range.startSeq; seq <= range.endSeq; seq++) {
      _RetransmitEntry? entry = _retransmitCache[seq];
      if (entry == null) {
        // Lost from cache; nothing we can do — the application layer will
        // see this as a TCP retransmit / app-level loss.
        continue;
      }
      BondedSchedulingDecision? d = scheduler.pickLink(
        bytes: entry.payload.length,
      );
      if (d == null) {
        // No healthy link; leave the entry in cache for the next round.
        return;
      }
      Uint8List frame = encodeBondedFrame(
        sessionId: config.sessionId,
        seq: seq,
        linkId: d.wireId,
        flags: BondedFlags.retransmit,
        payload: entry.payload,
      );
      sendOnLink(d.linkId, _sealIfEnabled(frame));
      _retransmissions++;
      observer?.call(d);
    }
  }

  /// Peer asked for retransmits. v0 payload is two big-endian u64s:
  /// [startSeq, endSeq]. Anything else is malformed and we drop it.
  void _handlePeerNak(Uint8List payload) {
    if (payload.length < 16) return;
    ByteData bd = ByteData.sublistView(payload);
    int startSeq = bd.getUint64(0, Endian.big);
    int endSeq = bd.getUint64(8, Endian.big);
    if (endSeq < startSeq) return;
    _retransmitRange(BondedNakRange(startSeq, endSeq));
  }

  void _restartKeepalives() {
    for (Timer t in _keepaliveTimers.values) {
      t.cancel();
    }
    _keepaliveTimers.clear();
    if (_disposed) return;
    for (BondedLinkState s in scheduler.states.values) {
      _keepaliveTimers[s.linkId] = Timer.periodic(
        config.keepaliveInterval,
        (Timer _) => _sendKeepalive(s.linkId, s.wireId),
      );
    }
  }

  void _sendKeepalive(String linkId, int wireId) {
    if (_disposed) return;
    // Payload: u64 LE inflight counter for this link, so the peer can
    // mirror our scheduling decisions when needed.
    int inflight = scheduler.inflightForTest(linkId);
    Uint8List body = Uint8List(8);
    ByteData.sublistView(body).setUint64(0, inflight, Endian.little);
    Uint8List frame = encodeBondedFrame(
      sessionId: config.sessionId,
      seq: 0, // keepalives carry no payload seq; receiver ignores it
      linkId: wireId,
      flags: BondedFlags.keepalive,
      payload: body,
    );
    sendOnLink(linkId, _sealIfEnabled(frame));
    _keepalives++;
  }

  String _linkIdForWireId(int wireId) {
    for (BondedLinkState s in scheduler.states.values) {
      if (s.wireId == wireId) {
        return s.linkId;
      }
    }
    return '';
  }

  /// Optional seal pass. Returns the input untouched when no [sealer] is
  /// wired (the common case in tests and during the lab loopback).
  Uint8List _sealIfEnabled(Uint8List frame) {
    BondedFrameSealer? s = sealer;
    if (s == null) return frame;
    return s(frame);
  }

  /// Optional unseal pass. Returns `null` when the [opener] rejects the
  /// bytes; the caller drops the wire blob silently in that case.
  Uint8List? _openIfEnabled(Uint8List wireBytes) {
    BondedFrameOpener? o = opener;
    if (o == null) return wireBytes;
    return o(wireBytes);
  }
}

class _RetransmitEntry {
  final String originalLinkId;
  final Uint8List payload;
  const _RetransmitEntry(this.originalLinkId, this.payload);
}
