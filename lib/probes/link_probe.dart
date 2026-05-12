import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../core/link.dart';
import '../core/link_metric.dart';

/// One probe attempt's outcome. Used internally and exposed for tests.
class ProbeOutcome {
  /// `null` if the probe failed (timeout, refused, network unreachable). When
  /// non-null, this is the connect / round-trip time in milliseconds.
  final double? rttMs;

  /// Human-readable failure reason. `null` on success.
  final String? error;

  const ProbeOutcome.success(this.rttMs) : error = null;
  const ProbeOutcome.failure(this.error) : rttMs = null;

  bool get isSuccess {
    return error == null;
  }
}

/// Function that performs a single probe attempt against [target] from
/// [sourceAddress]. Returns within [timeout] (with a synthetic failure on
/// timeout). Used by [LinkProbe] so unit tests can inject deterministic
/// behavior in place of real sockets.
typedef ProbeAttempt = Future<ProbeOutcome> Function({
  required InternetAddress target,
  required int port,
  required InternetAddress? sourceAddress,
  required Duration timeout,
});

/// Real TCP-connect probe. Binds the connect to [sourceAddress] (when given)
/// so we measure per-link RTT instead of whatever the default route uses.
///
/// We close the socket immediately after the SYN+ACK lands. The cost of a
/// 3-way handshake is acceptable at 1 Hz and is far less fragile than trying
/// to use ICMP from Dart (which would require raw sockets and elevated
/// privileges).
Future<ProbeOutcome> tcpConnectProbe({
  required InternetAddress target,
  required int port,
  required InternetAddress? sourceAddress,
  required Duration timeout,
}) async {
  Stopwatch sw = Stopwatch()..start();
  try {
    Socket socket = await Socket.connect(
      target,
      port,
      sourceAddress: sourceAddress,
      timeout: timeout,
    );
    double rtt = sw.elapsedMicroseconds / 1000.0;
    socket.destroy();
    return ProbeOutcome.success(rtt);
  } on SocketException catch (e) {
    return ProbeOutcome.failure(e.message);
  } on TimeoutException {
    return ProbeOutcome.failure('timeout');
  } catch (e) {
    return ProbeOutcome.failure(e.toString());
  }
}

/// Static + injectable configuration for a [LinkProbe].
class LinkProbeConfig {
  /// Interval between probe ticks. Default 1 s (Phase 2 acceptance criterion).
  final Duration tickInterval;

  /// Per-attempt connect timeout. Anything > 2 s is treated as "lost" so the
  /// loss metric remains responsive.
  final Duration attemptTimeout;

  /// Probe targets. Each tick uses one target, round-robined so a single
  /// reflector outage doesn't blackhole the metric.
  final List<ProbeTarget> targets;

  /// Size of the sliding RTT window used to compute jitter (population
  /// stddev) and loss percentage. 10 samples at 1 Hz = 10 s memory.
  final int windowSize;

  const LinkProbeConfig({
    this.tickInterval = const Duration(seconds: 1),
    this.attemptTimeout = const Duration(milliseconds: 2000),
    this.windowSize = 10,
    this.targets = const <ProbeTarget>[
      ProbeTarget(host: '1.1.1.1', port: 443),
      ProbeTarget(host: '8.8.8.8', port: 53),
    ],
  });
}

/// Probe target literal. Resolved synchronously via [InternetAddress.tryParse]
/// since we always use IP literals (DNS would itself be a confounding
/// variable for an RTT probe).
class ProbeTarget {
  final String host;
  final int port;

  const ProbeTarget({required this.host, required this.port});

  InternetAddress resolve() {
    InternetAddress? parsed = InternetAddress.tryParse(host);
    if (parsed != null) {
      return parsed;
    }
    return InternetAddress(host);
  }
}

/// Runs a periodic per-link probe loop and emits [LinkMetric] samples.
///
/// Each tick:
///
/// 1. Picks the next [ProbeTarget] from the round-robin cursor.
/// 2. Resolves the link's source address (sourceAddress > interfaceName look-up
///    from the live snapshot list provided by the caller).
/// 3. Calls [attempt] (defaults to [tcpConnectProbe]).
/// 4. Updates a sliding window of recent samples.
/// 5. Computes:
///    - `rttMs`     = latest successful RTT
///    - `jitterMs`  = population stddev of RTTs in window
///    - `loss`      = failures / window_size  (in `0.0..1.0`)
///    - `mos`       = E-model approximation via [LinkMetric.estimateMos]
/// 6. Emits a [LinkMetric] on [stream].
///
/// Throughput is intentionally **not** measured here — it's tied to actual
/// traffic, so the controller fills it in from transport flow stats.
class LinkProbe {
  final Link link;
  final LinkProbeConfig config;
  final ProbeAttempt _attempt;

  /// Resolves the link's source address each tick. Returning `null` means
  /// "no usable source" — the probe records a failure for the tick.
  final InternetAddress? Function() resolveSource;

  final StreamController<LinkMetric> _controller =
      StreamController<LinkMetric>.broadcast();
  final List<ProbeOutcome> _window = <ProbeOutcome>[];
  Timer? _timer;
  int _targetCursor = 0;
  bool _stopped = false;

  LinkProbe({
    required this.link,
    required this.resolveSource,
    this.config = const LinkProbeConfig(),
    ProbeAttempt? attempt,
  }) : _attempt = attempt ?? tcpConnectProbe;

  /// Live stream of [LinkMetric] samples. Replayable through a
  /// `BehaviorSubject` shape would be nicer but isn't worth a dep yet — the
  /// store keeps the last sample.
  Stream<LinkMetric> get stream {
    return _controller.stream;
  }

  /// Most recent metric emitted, or null if no tick has run yet. Useful for
  /// cold UI bootstrapping without subscribing.
  LinkMetric? get latest {
    return _latest;
  }

  LinkMetric? _latest;

  /// Begin ticking. Idempotent.
  void start() {
    if (_timer != null || _stopped) {
      return;
    }
    // Fire an immediate tick so the UI doesn't sit blank for a second on
    // startup; the periodic timer takes over after that.
    unawaited(_tick());
    _timer = Timer.periodic(config.tickInterval, (Timer _) {
      unawaited(_tick());
    });
  }

  /// Synchronously cancel the periodic timer. Useful from `dispose()` paths
  /// that need to release the timer immediately (e.g. the Flutter test
  /// binding's pending-timer assertion) before async cleanup runs.
  /// Idempotent.
  void cancelTimer() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Stop the probe and release resources. Safe to call multiple times.
  Future<void> stop() async {
    cancelTimer();
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  Future<void> _tick() async {
    if (_stopped) {
      return;
    }
    ProbeTarget target = config.targets[_targetCursor % config.targets.length];
    _targetCursor += 1;

    InternetAddress? source = resolveSource();
    ProbeOutcome outcome;
    if (source == null && link.sourceAddress != null) {
      // Caller knows what it wants but couldn't resolve — treat as failure.
      outcome = const ProbeOutcome.failure('no source address');
    } else {
      outcome = await _attempt(
        target: target.resolve(),
        port: target.port,
        sourceAddress: source,
        timeout: config.attemptTimeout,
      );
    }
    _record(outcome);
  }

  void _record(ProbeOutcome outcome) {
    _window.add(outcome);
    while (_window.length > config.windowSize) {
      _window.removeAt(0);
    }
    LinkMetric metric = _build(outcome);
    _latest = metric;
    if (!_controller.isClosed) {
      _controller.add(metric);
    }
  }

  LinkMetric _build(ProbeOutcome latestOutcome) {
    List<double> successfulRtts = <double>[];
    int failures = 0;
    for (ProbeOutcome o in _window) {
      if (o.isSuccess && o.rttMs != null) {
        successfulRtts.add(o.rttMs!);
      } else {
        failures += 1;
      }
    }
    double? rtt = latestOutcome.isSuccess
        ? latestOutcome.rttMs
        : (successfulRtts.isEmpty ? null : successfulRtts.last);
    double? jitter = _stddev(successfulRtts);
    double? loss = _window.isEmpty ? null : failures / _window.length;
    LinkMetric base = LinkMetric(
      linkId: link.id,
      capturedAt: DateTime.now().toUtc(),
      rttMs: rtt,
      jitterMs: jitter,
      loss: loss,
    );
    return base.withDerivedMos();
  }

  static double? _stddev(List<double> values) {
    if (values.length < 2) {
      return values.isEmpty ? null : 0.0;
    }
    double mean = values.reduce((double a, double b) => a + b) / values.length;
    double sumSq = 0.0;
    for (double v in values) {
      double d = v - mean;
      sumSq += d * d;
    }
    return math.sqrt(sumSq / values.length);
  }
}
