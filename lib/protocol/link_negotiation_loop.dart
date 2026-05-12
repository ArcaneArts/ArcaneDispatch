// Phase 11.3: mid-stream link negotiation loop.
//
// The `ProtocolLadder` answers "what transport works right now?" once,
// during cold-start. In production we also need to *re-run* the ladder
// when an active link starts losing packets — that's how Speedify
// transparently flips a link from UDP to TCP when an ISP starts shaping
// gaming traffic mid-call.
//
// `LinkNegotiationLoop` watches a metrics stream for trouble. When a
// link breaches the configured loss threshold for `consecutiveSamples`
// samples in a row, it asks the caller to run the ladder again. The
// caller provides a `negotiate(linkId)` closure that builds the ladder,
// runs `negotiate(probeFor)`, and returns the `LadderResult`. We keep
// probe construction outside the loop because real probes need access
// to the platform socket factories (Swift extension in production,
// `dart:io` in Pair & Share land); the loop is hermetic and unit
// testable in isolation.
library;

import 'dart:async';

import '../core/link.dart';
import '../core/link_metric.dart';
import 'protocol_ladder.dart';

/// Signature of the callback invoked when a link's active protocol changes
/// (either initially or after a re-negotiation). Implementers swap the
/// underlying transport plumbing on the caller side.
typedef OnProtocolChange =
    void Function(String linkId, LadderResult result);

/// Caller-supplied negotiator. Builds the per-link ladder + probes,
/// runs `negotiate(probeFor)`, and returns the result. May return a
/// failed [LadderResult] when no rung worked.
typedef LadderRunner = Future<LadderResult> Function(String linkId);

/// Configuration for [LinkNegotiationLoop]. Pulled into a struct so we
/// can grow it without breaking callers and so tests can override the
/// thresholds without flaky timer juggling.
class LinkNegotiationLoopConfig {
  /// Loss fraction above which a link is considered "in trouble". 0.05 =
  /// 5%, matching the Speedify default. Loss below this is ignored.
  final double lossThreshold;

  /// How many consecutive samples must exceed [lossThreshold] before we
  /// trigger a re-negotiation. Higher = less twitchy, lower = faster
  /// recovery.
  final int consecutiveSamples;

  /// Cool-down between re-negotiations on the same link. Without this a
  /// flapping link would re-run the ladder every metric tick.
  final Duration cooldown;

  /// Absolute ceiling for one negotiate pass. The ladder itself enforces
  /// per-step timeouts; this is the safety net so a runaway runner
  /// can't lock the loop forever.
  final Duration negotiateBudget;

  const LinkNegotiationLoopConfig({
    this.lossThreshold = 0.05,
    this.consecutiveSamples = 3,
    this.cooldown = const Duration(seconds: 30),
    this.negotiateBudget = const Duration(seconds: 10),
  }) : assert(lossThreshold > 0 && lossThreshold < 1),
       assert(consecutiveSamples > 0);
}

/// Per-link runtime state. Public for tests; not exported from the
/// library barrel.
class LinkNegotiationState {
  /// The currently active protocol (last successful [LadderResult]) —
  /// null until the first successful pass.
  LadderResult? active;

  /// Number of consecutive lossy samples observed since the last reset.
  int lossyStreak = 0;

  /// When the last negotiate finished. Used for cool-down.
  DateTime? lastNegotiateAt;

  /// True while a negotiate is in flight to prevent overlapping passes.
  bool inFlight = false;
}

/// Drives mid-stream protocol re-negotiation across a set of bonded links.
class LinkNegotiationLoop {
  final LinkNegotiationLoopConfig _cfg;
  final OnProtocolChange _onChange;
  final LadderRunner _runner;
  final DateTime Function() _now;

  final Map<String, LinkNegotiationState> _states = {};

  LinkNegotiationLoop({
    required LadderRunner runner,
    required OnProtocolChange onProtocolChange,
    LinkNegotiationLoopConfig config = const LinkNegotiationLoopConfig(),
    DateTime Function()? now,
  }) : _cfg = config,
       _onChange = onProtocolChange,
       _runner = runner,
       _now = now ?? DateTime.now;

  /// Snapshot of every known link's state. Defensive copy.
  Map<String, LinkNegotiationState> snapshot() {
    return Map.unmodifiable(_states);
  }

  /// Returns the currently active rung for [linkId], or null if none has
  /// been negotiated yet.
  LinkProtocol? activeFor(String linkId) =>
      _states[linkId]?.active?.chosen?.protocol;

  /// Trigger an initial negotiate for [link]. Idempotent: calling twice
  /// while a pass is in flight is a no-op.
  Future<LadderResult?> bootstrap(Link link) async {
    final state = _states.putIfAbsent(link.id, () => LinkNegotiationState());
    if (state.inFlight) return state.active;
    if (state.active != null && state.active!.isSuccess) return state.active;
    return await _runNegotiate(link.id);
  }

  /// Apply a fresh metric sample for [linkId]. May trigger a
  /// re-negotiation if the link has been lossy for [consecutiveSamples]
  /// samples in a row.
  Future<void> onMetric(String linkId, LinkMetric metric) async {
    final state = _states.putIfAbsent(linkId, () => LinkNegotiationState());
    final loss = metric.loss;
    if (loss != null && loss >= _cfg.lossThreshold) {
      state.lossyStreak += 1;
    } else {
      state.lossyStreak = 0;
    }
    if (state.lossyStreak < _cfg.consecutiveSamples) return;
    if (state.inFlight) return;
    final last = state.lastNegotiateAt;
    if (last != null && _now().difference(last) < _cfg.cooldown) {
      return;
    }
    await _runNegotiate(linkId);
  }

  /// Force a re-negotiation pass on [linkId]. Useful when an operator
  /// manually flips the protocol from the UI; the loop will still run
  /// the ladder so the caller doesn't have to know the wire details.
  Future<LadderResult?> forceNegotiate(String linkId) =>
      _runNegotiate(linkId);

  /// Mark a link as no-longer-tracked. Called when a link is removed
  /// from policy so we don't leak state forever.
  void forget(String linkId) {
    _states.remove(linkId);
  }

  /// Tears down all per-link state. Safe to call repeatedly.
  void dispose() {
    _states.clear();
  }

  Future<LadderResult?> _runNegotiate(String linkId) async {
    final state = _states.putIfAbsent(linkId, () => LinkNegotiationState());
    if (state.inFlight) return state.active;
    state.inFlight = true;
    try {
      final result = await _runner(linkId).timeout(
        _cfg.negotiateBudget,
        onTimeout: () => LadderResult(
          chosen: null,
          attempts: const <ProbeResult>[],
          totalElapsed: _cfg.negotiateBudget,
        ),
      );
      state.lastNegotiateAt = _now();
      if (result.isSuccess) {
        state.lossyStreak = 0;
        final changed = state.active?.chosen?.protocol !=
            result.chosen?.protocol;
        state.active = result;
        if (changed) {
          _onChange(linkId, result);
        }
      }
      return result;
    } finally {
      state.inFlight = false;
    }
  }
}
