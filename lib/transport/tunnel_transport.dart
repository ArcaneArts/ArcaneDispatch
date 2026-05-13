import 'dart:async';

import '../bridge/tunnel_channel.dart';
import '../core/link_metric.dart';
import '../core/policy.dart';
import '../core/proxy_event.dart';
import 'transport.dart';

/// System-wide [Transport] backed by the macOS Network Extension (Phase 5+).
///
/// Owns no packet logic of its own — everything that touches packets lives
/// in `macos/ArcaneDispatchTunnel/`. The Dart side's job is:
///
/// 1. Drive the platform lifecycle (install extension, start/stop VPN).
/// 2. Push the active [Policy] into the App Group container as JSON so the
///    extension reads the same snapshot the Dart UI shows.
/// 3. Surface status + metric streams back to the
///    [DispatchController] via the standard [Transport] streams.
class TunnelTransport implements Transport {
  /// Bridge to the Swift `TunnelManager`. Injected so tests can swap in a
  /// `FakeTunnelChannel` without spinning up a real MethodChannel.
  final TunnelChannel channel;

  /// How often to poll [TunnelChannel.status] when the tunnel is running.
  /// 1 s is fast enough for the UI to show a "stopping" transition without
  /// hammering the platform side.
  final Duration statusPollInterval;

  /// How often to drain per-link byte counters from the running extension.
  /// 1 s matches the SOCKS transport's emit cadence so the bond graphic
  /// animates at the same rate on both transports.
  final Duration throughputPollInterval;

  final LatestStream<TransportStatus> _state = LatestStream<TransportStatus>(
    TransportStatus(state: TransportState.stopped),
  );
  final StreamController<LinkMetric> _metrics =
      StreamController<LinkMetric>.broadcast();
  final StreamController<ProxyEvent> _events =
      StreamController<ProxyEvent>.broadcast();

  Timer? _statusTimer;
  Timer? _throughputTimer;
  TunnelStatus _lastStatus = TunnelStatus.unknown();
  bool _disposed = false;

  /// Cumulative bytes per link since [start]. Returned verbatim by
  /// [dataUsedSnapshot] so the UI's "Total used this cycle" reading
  /// reflects actual extension traffic, not just probe estimates.
  final Map<String, int> _totalIn = <String, int>{};
  final Map<String, int> _totalOut = <String, int>{};
  DateTime? _lastDrainAt;

  TunnelTransport({
    TunnelChannel? channel,
    this.statusPollInterval = const Duration(seconds: 1),
    this.throughputPollInterval = const Duration(seconds: 1),
  }) : channel = channel ?? TunnelChannel();

  @override
  TransportKind get kind {
    return TransportKind.tunnel;
  }

  @override
  TransportStatus get status {
    return _state.value;
  }

  @override
  Stream<TransportStatus> get states {
    return _state.stream;
  }

  @override
  Stream<LinkMetric> get metrics {
    return _metrics.stream;
  }

  @override
  Stream<ProxyEvent> get events {
    return _events.stream;
  }

  /// Bring the tunnel up. On platforms without the channel (any non-macOS
  /// host, including widget tests), surfaces a friendly error via
  /// [events] and leaves the transport in the failed state.
  @override
  Future<void> start(Policy policy) async {
    if (_disposed) {
      throw StateError('TunnelTransport has been disposed.');
    }
    _state.add(TransportStatus(state: TransportState.starting));
    _events.add(
      ProxyEvent(
        type: ProxyEventType.info,
        message: 'Starting system-wide tunnel…',
      ),
    );

    try {
      // 1. Make sure the System Extension is installed. If it's pending user
      //    approval we surface that to the UI and bail; the user has to
      //    approve in System Settings → Privacy & Security before retrying.
      TunnelInstallResult install = await channel.installExtension();
      if (!install.activated) {
        String msg = install.pending
            ? 'Network Extension is pending user approval. '
                  'Open System Settings → Privacy & Security and click Allow, '
                  'then start again.'
            : 'Failed to activate Network Extension: ${install.errorMessage ?? 'unknown error'}';
        _events.add(ProxyEvent(type: ProxyEventType.warning, message: msg));
        _state.add(
          TransportStatus(state: TransportState.failed, errorMessage: msg),
        );
        return;
      }

      // 2. Push policy + start. The platform side writes policy.json
      //    atomically before calling startVPNTunnel, so the extension reads
      //    the latest snapshot on its very first `readPolicy`.
      await channel.startTunnel(policy: policy);
      _events.add(
        ProxyEvent(
          type: ProxyEventType.info,
          message: 'Tunnel start requested. Awaiting connection…',
        ),
      );

      // 3. Poll status until the kernel reports connected or failed. The
      //    polling timer keeps running while the tunnel is up so we catch
      //    Wi-Fi-handoff "reasserting" transitions in [TransportState.starting].
      _scheduleStatusPolling();
      // 4. Drain per-link byte counters on a timer so the bond graphic
      //    animates from real traffic. We start it eagerly even before
      //    `connected` because the extension's accumulators are already
      //    valid as soon as packets start flowing — there's no harm in
      //    polling early and getting zeros.
      _scheduleThroughputPolling();
    } on TunnelUnavailableException {
      const String msg =
          'System-wide tunnel is only available on macOS with the '
          'Network Extension installed. Switch transport to SOCKS to '
          'continue using per-app proxy mode.';
      _events.add(ProxyEvent(type: ProxyEventType.warning, message: msg));
      _state.add(
        TransportStatus(state: TransportState.failed, errorMessage: msg),
      );
    } catch (e) {
      String msg = 'Tunnel start failed: $e';
      _events.add(ProxyEvent(type: ProxyEventType.error, message: msg));
      _state.add(
        TransportStatus(state: TransportState.failed, errorMessage: msg),
      );
    }
  }

  @override
  Future<void> stop() async {
    _statusTimer?.cancel();
    _statusTimer = null;
    _throughputTimer?.cancel();
    _throughputTimer = null;
    _totalIn.clear();
    _totalOut.clear();
    _lastDrainAt = null;
    _state.add(TransportStatus(state: TransportState.stopping));
    try {
      await channel.stopTunnel();
    } on TunnelUnavailableException {
      // Nothing to stop — bridge isn't even loaded on this host.
    } catch (e) {
      _events.add(
        ProxyEvent(
          type: ProxyEventType.warning,
          message: 'Tunnel stop returned an error: $e',
        ),
      );
    }
    _state.add(TransportStatus(state: TransportState.stopped));
    _events.add(
      ProxyEvent(type: ProxyEventType.info, message: 'Tunnel stopped.'),
    );
  }

  /// Push a new [Policy] to the extension. Cheap when the tunnel isn't
  /// running (writes policy.json only); sends a `reloadPolicy` message when
  /// the tunnel is connected so the extension hot-reloads without a restart.
  @override
  Future<void> updatePolicy(Policy policy) async {
    if (_disposed) {
      return;
    }
    try {
      if (_state.value.state == TransportState.running) {
        await channel.reloadPolicy(policy);
      } else {
        await channel.writePolicy(policy);
      }
    } on TunnelUnavailableException {
      // Bridge unavailable — nothing to do.
    } catch (e) {
      _events.add(
        ProxyEvent(
          type: ProxyEventType.warning,
          message: 'Policy push failed: $e',
        ),
      );
    }
  }

  @override
  Map<String, int> dataUsedSnapshot() {
    // Sum every link's totalIn + totalOut into one map. Keeps the API
    // shape simple — callers that want directional splits can subscribe
    // to [metrics] which carries the per-direction breakdown.
    Map<String, int> out = <String, int>{};
    Set<String> ids = <String>{..._totalIn.keys, ..._totalOut.keys};
    for (String id in ids) {
      out[id] = (_totalIn[id] ?? 0) + (_totalOut[id] ?? 0);
    }
    return out;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _statusTimer?.cancel();
    _statusTimer = null;
    _throughputTimer?.cancel();
    _throughputTimer = null;
    await _state.close();
    await _metrics.close();
    await _events.close();
  }

  // --- internals -----------------------------------------------------------

  /// Start (or reset) the status-poll timer. Mapping
  /// `TunnelStatusKind -> TransportState` happens in [_publishStatus]
  /// so the [Transport] contract stays the single source of truth for the UI.
  void _scheduleStatusPolling() {
    _statusTimer?.cancel();
    // Kick once immediately so the UI doesn't have to wait a full tick.
    unawaited(_pollStatus());
    _statusTimer = Timer.periodic(statusPollInterval, (Timer _) {
      unawaited(_pollStatus());
    });
  }

  Future<void> _pollStatus() async {
    if (_disposed) {
      return;
    }
    try {
      TunnelStatus next = await channel.status();
      _publishStatus(next);
    } on TunnelUnavailableException {
      // Channel went away — fall back to stopped to avoid a stuck UI.
      _publishStatus(
        TunnelStatus(
          kind: TunnelStatusKind.stopped,
          extensionBundleId: _lastStatus.extensionBundleId,
        ),
      );
    } catch (_) {
      // Swallow — the next tick retries. Reporting every transient hiccup
      // to the user would be noisy.
    }
  }

  /// Drain throughput counters from the extension on a timer. Each
  /// drain returns the bytes accumulated since the previous call, which
  /// we turn into a per-direction bytes-per-second rate using elapsed
  /// wall-clock time. Each link gets one [LinkMetric] event on
  /// [metrics] so the bond graphic's per-spoke flow animates from real
  /// traffic.
  void _scheduleThroughputPolling() {
    _throughputTimer?.cancel();
    _lastDrainAt = DateTime.now();
    _throughputTimer = Timer.periodic(throughputPollInterval, (Timer _) {
      unawaited(_pollThroughput());
    });
  }

  Future<void> _pollThroughput() async {
    if (_disposed) {
      return;
    }
    List<TunnelThroughputSample> samples;
    try {
      samples = await channel.getThroughput();
    } on TunnelUnavailableException {
      _throughputTimer?.cancel();
      _throughputTimer = null;
      return;
    } catch (_) {
      // Transient — retry on next tick. The extension might be in the
      // middle of a state transition.
      return;
    }
    DateTime now = DateTime.now();
    Duration since = _lastDrainAt != null
        ? now.difference(_lastDrainAt!)
        : throughputPollInterval;
    _lastDrainAt = now;
    // Guard against the first tick (which could report a huge delta if
    // the timer is wildly off) and against jittery wall clocks.
    double seconds = since.inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds < 0.05) {
      seconds =
          throughputPollInterval.inMicroseconds /
          Duration.microsecondsPerSecond;
    }
    for (TunnelThroughputSample sample in samples) {
      double bpsIn = sample.bytesIn / seconds;
      double bpsOut = sample.bytesOut / seconds;
      _totalIn[sample.linkId] = (_totalIn[sample.linkId] ?? 0) + sample.bytesIn;
      _totalOut[sample.linkId] =
          (_totalOut[sample.linkId] ?? 0) + sample.bytesOut;
      _metrics.add(
        LinkMetric(
          linkId: sample.linkId,
          rttMs: 0,
          loss: 0,
          bpsIn: bpsIn,
          bpsOut: bpsOut,
          capturedAt: now,
        ),
      );
    }
  }

  void _publishStatus(TunnelStatus next) {
    if (next.kind == _lastStatus.kind &&
        next.lastError == _lastStatus.lastError) {
      return;
    }
    _lastStatus = next;
    switch (next.kind) {
      case TunnelStatusKind.connected:
        _state.add(
          TransportStatus(
            state: TransportState.running,
            endpoint: next.extensionBundleId,
          ),
        );
        _events.add(
          ProxyEvent(type: ProxyEventType.info, message: 'Tunnel connected.'),
        );
        break;
      case TunnelStatusKind.starting:
        _state.add(TransportStatus(state: TransportState.starting));
        break;
      case TunnelStatusKind.stopping:
        _state.add(TransportStatus(state: TransportState.stopping));
        break;
      case TunnelStatusKind.stopped:
        _statusTimer?.cancel();
        _statusTimer = null;
        _state.add(TransportStatus(state: TransportState.stopped));
        break;
      case TunnelStatusKind.failed:
        _statusTimer?.cancel();
        _statusTimer = null;
        _state.add(
          TransportStatus(
            state: TransportState.failed,
            errorMessage: next.lastError,
          ),
        );
        _events.add(
          ProxyEvent(
            type: ProxyEventType.error,
            message: next.lastError ?? 'Tunnel failed.',
          ),
        );
        break;
      case TunnelStatusKind.extensionMissing:
        _statusTimer?.cancel();
        _statusTimer = null;
        _state.add(
          TransportStatus(
            state: TransportState.failed,
            errorMessage:
                'Network Extension is not installed. Click Start to install.',
          ),
        );
        break;
      case TunnelStatusKind.unknown:
        // Don't churn the state machine on first-poll uncertainty.
        break;
    }
  }
}
