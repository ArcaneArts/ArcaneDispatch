import 'dart:async';

import '../core/link.dart';
import '../core/link_metric.dart';
import '../core/policy.dart';
import 'policy_engine.dart';

/// One health-status snapshot covering every configured [Link] plus the
/// kill-switch state.
///
/// Emitted by [LinkSupervisor.events] whenever the supervisor recomputes its
/// view of the world. Consumers should treat the map as authoritative and
/// fully replace any prior status they were tracking.
///
/// Why a snapshot rather than deltas: the supervisor publishes at most one
/// event per evaluation tick, so the snapshot stays small (one entry per
/// link). Diffing happens client-side when it matters — the controller
/// compares the active group to decide whether to restart the transport.
class LinkHealthEvent {
  /// Per-link [LinkStatus] after this tick. Links not present in the policy
  /// are not included.
  final Map<String, LinkStatus> statuses;

  /// The [PolicyEngine]'s eligibility verdict for this tick. Mirrors what
  /// the transport's `applyMetrics` would see if it re-evaluated now.
  final PolicyDecision decision;

  /// True iff the supervisor is currently asserting the kill switch.
  ///
  /// Definition: `policy.killSwitch == true` AND no link is currently in
  /// the eligible set. Once one returns, the kill switch releases on the
  /// very next event.
  final bool killSwitchActive;

  /// When this event was emitted (UTC).
  final DateTime timestamp;

  const LinkHealthEvent({
    required this.statuses,
    required this.decision,
    required this.killSwitchActive,
    required this.timestamp,
  });

  /// Convenience: list all links currently mapped to the given status.
  List<String> linksWithStatus(LinkStatus status) {
    List<String> result = <String>[];
    statuses.forEach((String id, LinkStatus s) {
      if (s == status) {
        result.add(id);
      }
    });
    return result;
  }
}

/// Pure-Dart arbiter that turns the metric stream into per-link health
/// statuses and a kill-switch verdict.
///
/// The supervisor owns *no* sockets and runs *no* network IO. It accepts:
/// * The active [Policy] (re-applied on every change).
/// * A trickle of [LinkMetric] samples (one per probe tick).
/// * Optional [dataUsedSnapshot] callbacks for cap-aware eligibility.
///
/// On each input, it re-runs [PolicyEngine.evaluate] and broadcasts a
/// [LinkHealthEvent]. The controller subscribes and drives the transport:
/// when the active group changes, it calls `transport.updatePolicy`; when
/// the kill switch fires, it calls `transport.stop`.
///
/// Threading: single-threaded by design. All mutations happen on the
/// [Stream.listen] callback's thread, which on Flutter is always the UI
/// isolate. The event stream is a broadcast so multiple consumers can
/// subscribe (UI + controller).
class LinkSupervisor {
  final PolicyEngine engine;

  /// Optional callback returning the current per-link byte usage. When
  /// present, its return is forwarded to [PolicyEngine.evaluate] so data caps
  /// take effect without round-tripping through the controller.
  final Map<String, int> Function()? dataUsedProvider;

  final DateTime Function() _now;
  final StreamController<LinkHealthEvent> _events =
      StreamController<LinkHealthEvent>.broadcast();

  Policy? _policy;
  final Map<String, LinkMetric> _metrics = <String, LinkMetric>{};
  bool _disposed = false;
  LinkHealthEvent? _last;

  LinkSupervisor({
    this.engine = const PolicyEngine(),
    this.dataUsedProvider,
    DateTime Function() now = _systemNow,
  }) : _now = now;

  /// Broadcast stream of health updates. Subscribe in `initState` /
  /// controller init; cancel before disposing the supervisor.
  Stream<LinkHealthEvent> get events {
    return _events.stream;
  }

  /// Most recent [LinkHealthEvent] this supervisor emitted. `null` until
  /// the first evaluation. Useful for UI cold-boot and for tests that want
  /// the latest snapshot without subscribing.
  LinkHealthEvent? get lastEvent {
    return _last;
  }

  /// True when the kill switch is currently active. Mirrors
  /// [LinkHealthEvent.killSwitchActive] from the most recent emit.
  bool get isKillSwitchActive {
    return _last?.killSwitchActive ?? false;
  }

  /// Replace the active policy. Triggers an immediate re-evaluation so the
  /// caller sees the new health state in the next [events] frame.
  void updatePolicy(Policy policy) {
    if (_disposed) {
      return;
    }
    _policy = policy;
    // Drop metrics for links that no longer exist so the cache stays bounded.
    Set<String> liveIds = <String>{for (Link link in policy.links) link.id};
    _metrics.removeWhere((String id, LinkMetric _) => !liveIds.contains(id));
    _evaluate();
  }

  /// Record a single [LinkMetric] sample and re-evaluate.
  ///
  /// Cheap on the hot path (one map write + one engine call). For bulk
  /// updates, use [updateMetrics] which evaluates exactly once at the end.
  void updateMetric(LinkMetric metric) {
    if (_disposed) {
      return;
    }
    _metrics[metric.linkId] = metric;
    _evaluate();
  }

  /// Replace the metric snapshot in bulk. Used by tests and by the
  /// controller's warm-start path (where the metric store yields a Map).
  void updateMetrics(Map<String, LinkMetric> metrics) {
    if (_disposed) {
      return;
    }
    _metrics
      ..clear()
      ..addAll(metrics);
    _evaluate();
  }

  /// Tear down the supervisor. Subsequent updates are silently dropped.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _events.close();
  }

  void _evaluate() {
    Policy? policy = _policy;
    if (policy == null) {
      return;
    }
    Map<String, int> dataUsed = dataUsedProvider?.call() ?? const <String, int>{};
    PolicyDecision decision = engine.evaluate(
      policy: policy,
      metrics: Map<String, LinkMetric>.unmodifiable(_metrics),
      dataUsedOverride: dataUsed,
    );

    Map<String, LinkStatus> statuses = <String, LinkStatus>{};
    Set<String> eligibleIds = <String>{
      for (EligibleLink slot in decision.eligible) slot.link.id,
    };
    Map<String, IneligibilityReason> reasonById =
        <String, IneligibilityReason>{
      for (IneligibleLink i in decision.ineligible) i.link.id: i.reason,
    };

    for (Link link in policy.links) {
      if (link.priority == LinkPriority.never) {
        statuses[link.id] = LinkStatus.disabled;
        continue;
      }
      if (eligibleIds.contains(link.id)) {
        statuses[link.id] = LinkStatus.healthy;
        continue;
      }
      IneligibilityReason? reason = reasonById[link.id];
      switch (reason) {
        case IneligibilityReason.groupSuperseded:
          // The link is fine but its group lost the priority cascade.
          statuses[link.id] = LinkStatus.degraded;
          break;
        case IneligibilityReason.highLoss:
        case IneligibilityReason.highRtt:
        case IneligibilityReason.noSource:
        case IneligibilityReason.dataCapExhausted:
          statuses[link.id] = LinkStatus.unhealthy;
          break;
        case IneligibilityReason.never:
          statuses[link.id] = LinkStatus.disabled;
          break;
        case null:
          statuses[link.id] = LinkStatus.unknown;
          break;
      }
    }

    bool killSwitch = policy.killSwitch && !decision.hasEligible;
    LinkHealthEvent event = LinkHealthEvent(
      statuses: Map<String, LinkStatus>.unmodifiable(statuses),
      decision: decision,
      killSwitchActive: killSwitch,
      timestamp: _now().toUtc(),
    );
    _last = event;
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  static DateTime _systemNow() {
    return DateTime.now();
  }
}
