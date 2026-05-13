// Per-packet link selector for the bonded transport (Speed mode v0).
//
// Mirrored on the Swift side by
// `macos/ArcaneDispatchTunnel/Bonded/BondedScheduler.swift`. The contract is
// "given a chunk of bytes, return the [linkId] that should carry it." The
// scheduler is *not* responsible for transmission — it only picks. The actual
// UDP send happens in the session driver so the scheduler stays
// trivially-testable.
//
// Algorithm (Speed mode):
//
//   credit(link) = bandwidthBytesPerSec(link) × rtt(link) − inflightBytes(link)
//
// On every `pickLink`:
//   1. Drop links whose status isn't healthy/degraded and whose priority is
//      `never`. Empty result → returns null (caller's job to apply policy).
//   2. Compute credit for each remaining link. If multiple links tie (e.g.
//      identical bandwidth/RTT, all idle), fall back to a stable weighted
//      round-robin so the load distribution converges to the configured
//      weights when credit signals are absent.
//   3. Once a link is picked, the scheduler "books" the bytes (adds to its
//      inflight counter) so the next pick reflects the in-progress send.
//      The caller MUST call [completeSend] once the bytes have been ACKed or
//      timed out, otherwise the link will look perpetually congested.
//
// Bandwidth comes from the latest [LinkMetric.throughputBytesPerSec]; if the
// metric is missing or stale we default to a small floor so the link still
// participates rather than starving.

import 'dart:math' as math;

import '../core/link.dart';
import '../core/link_metric.dart';

/// Snapshot of the data the scheduler needs to make a decision. Decoupled
/// from `LinkMetric` so the bonded layer doesn't have to import the probe
/// machinery; the controller adapts metrics into [BondedLinkState] before
/// pushing them in.
class BondedLinkState {
  /// Foreign key into `Link.id`.
  final String linkId;

  /// Numeric id stamped into the wire frame (`linkId` field). Picked by the
  /// session at registration time; we keep it separate from the string id so
  /// the protocol stays compact.
  final int wireId;

  /// Routing priority bucket from the policy.
  final LinkPriority priority;

  /// Health from the supervisor.
  final LinkStatus status;

  /// Integer weight inside the priority bucket. Drives the RR fallback.
  final int weight;

  /// Smoothed RTT estimate, milliseconds. Higher = worse credit.
  final double rttMs;

  /// Throughput estimate from the probe, bytes/sec. Higher = more credit.
  final double bandwidthBps;

  /// Bytes currently in flight on this link (booked by [BondedScheduler.pickLink]
  /// and decremented by [BondedScheduler.completeSend]).
  final int inflightBytes;

  /// Observed packet-loss fraction, 0.0–1.0. Strategies treat 0 as
  /// "unknown".
  final double lossFraction;

  const BondedLinkState({
    required this.linkId,
    required this.wireId,
    this.priority = LinkPriority.primary,
    this.status = LinkStatus.unknown,
    this.weight = 1,
    this.rttMs = 50.0,
    this.bandwidthBps = 1_000_000.0,
    this.inflightBytes = 0,
    this.lossFraction = 0.0,
  });

  BondedLinkState copyWith({
    LinkPriority? priority,
    LinkStatus? status,
    int? weight,
    double? rttMs,
    double? bandwidthBps,
    int? inflightBytes,
    double? lossFraction,
  }) {
    return BondedLinkState(
      linkId: linkId,
      wireId: wireId,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      weight: weight ?? this.weight,
      rttMs: rttMs ?? this.rttMs,
      bandwidthBps: bandwidthBps ?? this.bandwidthBps,
      inflightBytes: inflightBytes ?? this.inflightBytes,
      lossFraction: lossFraction ?? this.lossFraction,
    );
  }

  /// Build a state from a [Link] + optional [LinkMetric]. Convenience for
  /// the policy-engine → scheduler glue layer.
  factory BondedLinkState.fromLink(
    Link link, {
    required int wireId,
    LinkMetric? metric,
  }) {
    // We use bpsOut (egress throughput) for the credit formula since the
    // scheduler is choosing outbound paths. Falls back to bpsIn, then to a
    // sensible default when neither is sampled yet so newly-added links
    // still participate in the first decision rather than starving for a
    // probe cycle.
    double bandwidth = metric?.bpsOut ?? metric?.bpsIn ?? 1_000_000.0;
    double rtt = metric?.rttMs ?? 50.0;
    double loss = metric?.loss ?? 0.0;
    return BondedLinkState(
      linkId: link.id,
      wireId: wireId,
      priority: link.priority,
      status: link.status,
      weight: link.weight,
      rttMs: rtt,
      bandwidthBps: bandwidth,
      lossFraction: loss,
    );
  }
}

/// Result of a single scheduling decision. The wireId is what the framer
/// stamps into the outgoing packet.
class BondedSchedulingDecision {
  /// Foreign key into the policy.
  final String linkId;

  /// Wire id stamped into the bonded frame.
  final int wireId;

  /// Credit at the moment of selection — exposed mostly for diagnostics /
  /// metrics. UI can plot "winning credit per pick" to debug starvation.
  final double credit;

  /// True iff this pick was made via RR fallback because credit signals
  /// tied. Useful for debugging "why didn't link X get traffic?".
  final bool wasRoundRobinFallback;

  const BondedSchedulingDecision({
    required this.linkId,
    required this.wireId,
    required this.credit,
    this.wasRoundRobinFallback = false,
  });
}

/// Speed-mode credit-based scheduler.
///
/// Lifecycle: build once per session, push state with [updateLinks] whenever
/// policy or metrics change, ask for a decision with [pickLink], settle the
/// inflight counter with [completeSend] once a packet is ACKed/dropped.
class BondedScheduler {
  final Map<String, BondedLinkState> _states = <String, BondedLinkState>{};
  // Stable iteration order for the RR fallback. Whenever updateLinks adds /
  // removes links we recompute the cursor's modulus.
  final List<String> _order = <String>[];
  int _rrCursor = 0;

  /// Floor for the bandwidth estimate. Without this an idle link with a
  /// brand-new metric of 0 B/s would always lose, even when it's the only
  /// healthy link.
  final double minBandwidthBps;

  /// Floor for the RTT estimate (ms). 1 ms keeps the credit formula from
  /// degenerating into infinity on loopback.
  final double minRttMs;

  BondedScheduler({
    this.minBandwidthBps = 50_000.0, // 50 kB/s
    this.minRttMs = 1.0,
  });

  /// Snapshot of the current view; copied so the caller can't mutate
  /// internal state.
  Map<String, BondedLinkState> get states {
    return Map<String, BondedLinkState>.unmodifiable(_states);
  }

  int get linkCount => _states.length;

  /// Replace the link set. Existing inflight counters for links that survive
  /// the update are preserved; entries that disappear have their inflight
  /// silently dropped (the session driver should call [completeSend] before
  /// removing a link to keep accounting clean).
  void updateLinks(Iterable<BondedLinkState> incoming) {
    Map<String, BondedLinkState> nextStates = <String, BondedLinkState>{};
    for (BondedLinkState s in incoming) {
      BondedLinkState? prior = _states[s.linkId];
      nextStates[s.linkId] = s.copyWith(
        inflightBytes: prior?.inflightBytes ?? s.inflightBytes,
      );
    }
    _states
      ..clear()
      ..addAll(nextStates);
    _order
      ..clear()
      ..addAll(nextStates.keys);
    if (_order.isEmpty) {
      _rrCursor = 0;
    } else {
      _rrCursor %= _order.length;
    }
  }

  /// Pick a link for an outbound packet of [bytes] bytes. Returns null when
  /// no link is eligible — callers should treat this as "drop or queue".
  /// The scheduler does not block / queue itself.
  ///
  /// [inflightFraction] scales the BDP cap used in the credit formula.
  /// Speed mode passes 1.0 by default. Values outside `[0.05, 1.0]`
  /// are clamped to keep the math sensible.
  BondedSchedulingDecision? pickLink({
    required int bytes,
    double inflightFraction = 1.0,
  }) {
    if (_states.isEmpty || bytes <= 0) {
      return null;
    }
    double frac = inflightFraction;
    if (frac < 0.05) frac = 0.05;
    if (frac > 1.0) frac = 1.0;
    List<String> eligible = _eligibleByPriority();
    if (eligible.isEmpty) {
      return null;
    }

    double bestCredit = double.negativeInfinity;
    String? winner;
    for (String id in eligible) {
      BondedLinkState s = _states[id]!;
      double credit = _credit(s, frac);
      if (credit > bestCredit) {
        bestCredit = credit;
        winner = id;
      }
    }

    bool wasRR = false;
    if (winner == null) {
      // Should be unreachable because eligible was non-empty, but guard for
      // arithmetic surprises (-inf vs -inf etc.).
      winner = eligible.first;
      wasRR = true;
      bestCredit = 0.0;
    } else {
      // If two or more eligible links share `bestCredit`, prefer the RR
      // fallback so weights converge to the configured ratio.
      int tieCount = 0;
      for (String id in eligible) {
        if ((bestCredit - _credit(_states[id]!, frac)).abs() < 1e-6) {
          tieCount++;
        }
      }
      if (tieCount > 1) {
        winner = _roundRobinPick(eligible);
        wasRR = true;
      }
    }

    // Book the bytes as inflight so subsequent picks see realistic credit.
    BondedLinkState s = _states[winner]!;
    _states[winner] = s.copyWith(inflightBytes: s.inflightBytes + bytes);
    return BondedSchedulingDecision(
      linkId: winner,
      wireId: s.wireId,
      credit: bestCredit,
      wasRoundRobinFallback: wasRR,
    );
  }

  /// Manually book [bytes] of inflight on [linkId]. Strategies that
  /// synthesise their picks (e.g. Redundant duplicating to every link)
  /// call this directly so the scheduler's credit math stays accurate
  /// when the user later switches back to Speed mode.
  void bookInflight(String linkId, int bytes) {
    BondedLinkState? s = _states[linkId];
    if (s == null) return;
    _states[linkId] = s.copyWith(inflightBytes: s.inflightBytes + bytes);
  }

  /// Release [bytes] from the link's inflight counter, signalling that the
  /// packet has been ACKed (or given up on after a timeout — either way the
  /// scheduler should stop pretending those bytes are still in flight).
  void completeSend(String linkId, int bytes) {
    BondedLinkState? s = _states[linkId];
    if (s == null) {
      return;
    }
    int next = math.max(0, s.inflightBytes - bytes);
    _states[linkId] = s.copyWith(inflightBytes: next);
  }

  /// Public credit accessor. Strategies consult it when they want to
  /// consider non-default link populations without
  /// invoking the booking side-effect of [pickLink]. Returns 0 when the
  /// link is unknown.
  double creditFor(String linkId, {double inflightFraction = 1.0}) {
    BondedLinkState? s = _states[linkId];
    if (s == null) {
      return 0.0;
    }
    double frac = inflightFraction.clamp(0.05, 1.0).toDouble();
    return _credit(s, frac);
  }

  /// Diagnostic alias retained for tests written before [creditFor] was
  /// promoted to a stable API. New code should call [creditFor].
  double creditForTest(String linkId, {double inflightFraction = 1.0}) =>
      creditFor(linkId, inflightFraction: inflightFraction);

  /// Inflight bytes accessor used by tests + telemetry.
  int inflightForTest(String linkId) {
    return _states[linkId]?.inflightBytes ?? 0;
  }

  // ---------------------------------------------------------------------
  // internals
  // ---------------------------------------------------------------------

  double _credit(BondedLinkState s, double frac) {
    double bandwidth = s.bandwidthBps < minBandwidthBps
        ? minBandwidthBps
        : s.bandwidthBps;
    double rttSec = (s.rttMs < minRttMs ? minRttMs : s.rttMs) / 1000.0;
    // Bandwidth × delay = the BDP "slot" the link can absorb. Subtract
    // inflight to model remaining headroom. Healthier link → more credit.
    double bdp = bandwidth * rttSec * frac;
    return bdp - s.inflightBytes.toDouble();
  }

  /// Return the eligible links ordered by priority (primary → backup, never
  /// excluded). Unhealthy / disabled links are filtered. We do priority
  /// filtering as a separate pass so credit is only compared inside the
  /// "best" bucket the policy allows.
  List<String> _eligibleByPriority() {
    if (_states.isEmpty) {
      return const <String>[];
    }
    // Find the best bucket that has any healthy member.
    for (LinkPriority bucket in <LinkPriority>[
      LinkPriority.primary,
      LinkPriority.secondary,
      LinkPriority.backup,
    ]) {
      List<String> ids = <String>[];
      for (String id in _order) {
        BondedLinkState s = _states[id]!;
        if (s.priority != bucket) continue;
        if (s.status == LinkStatus.unhealthy ||
            s.status == LinkStatus.disabled) {
          continue;
        }
        ids.add(id);
      }
      if (ids.isNotEmpty) {
        return ids;
      }
    }
    return const <String>[];
  }

  String _roundRobinPick(List<String> eligible) {
    if (eligible.length == 1) {
      _rrCursor = (_rrCursor + 1) % _order.length;
      return eligible.first;
    }
    // Iterate the master order so weights stay deterministic — the eligible
    // list is already filtered by priority/health.
    int start = _rrCursor;
    String picked = eligible.first;
    for (int i = 0; i < _order.length; i++) {
      int idx = (start + i) % _order.length;
      String candidate = _order[idx];
      if (eligible.contains(candidate)) {
        picked = candidate;
        _rrCursor = (idx + 1) % _order.length;
        return picked;
      }
    }
    return picked;
  }
}
