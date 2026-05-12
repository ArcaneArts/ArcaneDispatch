// Captive portal probe + detector.
//
// Hotel/airport/coffee-shop Wi-Fi often hijacks DNS or HTTP traffic until
// the user accepts a ToS. The Network Extension can't tell from L3 alone;
// we have to *fingerprint* the response. Apple uses
// http://captive.apple.com/ for this purpose and ships a tiny HTML page
// whose body matches `<TITLE>Success</TITLE>\n<BODY>\nSuccess\n</BODY>`.
// Anything else means the link is captive: it could be a 302 to a portal,
// a transparent proxy injecting HTML, a DNS hijack returning a synthetic
// 200, or — most adversarially — a portal returning a 200 with a login
// form that *contains* the word "Success" but not in `<TITLE>`. We match
// the explicit title tag to keep false positives low.
//
// Probing is plain HTTP (not HTTPS) on purpose. Captive portals can't
// hijack TLS without an MITM certificate, so HTTPS would either succeed
// (telling us nothing about captivity) or fail with a TLS error (telling
// us only that *something* is broken). HTTP gives us a clean signal.
//
// Design constraints:
//   * Per-link source address binding (mirrors `LinkProbe`).
//   * Cheap — 1 GET every 30 s (configurable). Falls back to a 60 s slow
//     poll after 3 consecutive captive results so we don't hammer the
//     portal.
//   * Returns a state machine (`pass`, `captive`, `error`) rather than a
//     boolean so the UI can distinguish "no network at all" from
//     "captive".
//   * Has an explicit `Clock` injection point so tests don't have to wait
//     for the real periodic timer.

import 'dart:async';
import 'dart:io';

import '../core/link.dart';

/// Result of a single captive portal probe attempt.
enum CaptivePortalProbeResult {
  /// The body matched the Apple "Success" page exactly. The link is open.
  pass,

  /// The response came back but didn't match — the link is *probably*
  /// behind a captive portal (or some other middlebox). Surface this in
  /// the UI as "Action required".
  captive,

  /// The probe failed (TCP refused, DNS hijack returning bogus IP, TLS
  /// error, timeout, etc.). Not captive per se — could be no internet at
  /// all. UI should distinguish from `captive`.
  error,
}

/// One probe outcome along with diagnostic metadata.
class CaptivePortalProbeOutcome {
  /// Coarse status used by the detector state machine.
  final CaptivePortalProbeResult result;

  /// HTTP status code from the probe, when reachable. `null` for network
  /// errors. Useful for distinguishing a 302 redirect from a transparent
  /// proxy returning a synthetic 200.
  final int? statusCode;

  /// Error message when [result] is `error`. `null` otherwise.
  final String? error;

  /// Wall-clock at which this outcome was sampled. UTC.
  final DateTime capturedAt;

  const CaptivePortalProbeOutcome({
    required this.result,
    required this.capturedAt,
    this.statusCode,
    this.error,
  });

  bool get isPass {
    return result == CaptivePortalProbeResult.pass;
  }

  bool get isCaptive {
    return result == CaptivePortalProbeResult.captive;
  }
}

/// Function that performs a single captive-portal probe. Used so tests can
/// inject a deterministic stand-in for real HTTP. Returns within
/// [timeout]; treats timeouts as `error`.
typedef CaptivePortalProbeFn = Future<CaptivePortalProbeOutcome> Function({
  required Uri target,
  required InternetAddress? sourceAddress,
  required Duration timeout,
  required DateTime now,
});

/// Default Apple-style probe target. Public per Apple's documentation:
/// the page is intentionally short, plaintext, and stable, and Apple
/// guarantees it will continue to return the canonical body so OS-level
/// captive-portal detection keeps working.
final Uri appleCaptiveProbeUri = Uri.parse('http://captive.apple.com/');

/// Body Apple's captive endpoint returns when the link is uncaptured.
/// We require this exact substring rather than a regex to keep the match
/// cheap and to avoid being fooled by portals whose login pages contain
/// the word "Success" in body copy.
const String captiveAppleSuccessMarker = '<TITLE>Success</TITLE>';

/// Real HTTP-based captive probe. Issues a plain GET, reads up to 2 KiB
/// of body (Apple's response is ~70 B; cap protects against a malicious
/// portal trying to exhaust memory), and matches against
/// [captiveAppleSuccessMarker].
///
/// The probe binds the underlying TCP socket to [sourceAddress] when
/// given, so we measure the *specified link* rather than whatever the
/// default route currently is. This is the same trick `LinkProbe` uses.
Future<CaptivePortalProbeOutcome> httpCaptivePortalProbe({
  required Uri target,
  required InternetAddress? sourceAddress,
  required Duration timeout,
  required DateTime now,
}) async {
  // We can't easily bind an HttpClient to a source address (the
  // high-level API doesn't expose it). When `sourceAddress` is null we
  // use the default `HttpClient`; when non-null we open a raw socket so
  // we can pin to the interface.
  if (sourceAddress == null) {
    return _probeViaHttpClient(target: target, timeout: timeout, now: now);
  }
  return _probeViaRawSocket(
    target: target,
    sourceAddress: sourceAddress,
    timeout: timeout,
    now: now,
  );
}

Future<CaptivePortalProbeOutcome> _probeViaHttpClient({
  required Uri target,
  required Duration timeout,
  required DateTime now,
}) async {
  HttpClient client = HttpClient()
    ..connectionTimeout = timeout
    // Don't auto-follow redirects: a 302 to the portal *is* the
    // captive signal we want to see.
    ..autoUncompress = false;
  try {
    HttpClientRequest req = await client.getUrl(target).timeout(timeout);
    req.followRedirects = false;
    HttpClientResponse resp = await req.close().timeout(timeout);
    // Read at most 2 KiB of body so a malicious portal can't OOM us.
    List<int> bytes = <int>[];
    int cap = 2048;
    Completer<void> done = Completer<void>();
    StreamSubscription<List<int>> sub = resp.listen(
      (List<int> chunk) {
        int remaining = cap - bytes.length;
        if (remaining <= 0) return;
        if (chunk.length <= remaining) {
          bytes.addAll(chunk);
        } else {
          bytes.addAll(chunk.sublist(0, remaining));
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      cancelOnError: true,
    );
    try {
      await done.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
    String body = String.fromCharCodes(bytes);
    return classifyCaptiveResponse(
      statusCode: resp.statusCode,
      body: body,
      now: now,
    );
  } on TimeoutException {
    return CaptivePortalProbeOutcome(
      result: CaptivePortalProbeResult.error,
      capturedAt: now,
      error: 'timeout',
    );
  } catch (e) {
    return CaptivePortalProbeOutcome(
      result: CaptivePortalProbeResult.error,
      capturedAt: now,
      error: e.toString(),
    );
  } finally {
    client.close(force: true);
  }
}

Future<CaptivePortalProbeOutcome> _probeViaRawSocket({
  required Uri target,
  required InternetAddress sourceAddress,
  required Duration timeout,
  required DateTime now,
}) async {
  int port = target.hasPort ? target.port : 80;
  String host = target.host;
  String path = target.path.isEmpty ? '/' : target.path;
  Socket? socket;
  try {
    socket = await Socket.connect(
      host,
      port,
      sourceAddress: sourceAddress,
      timeout: timeout,
    );
    socket.add(
      'GET $path HTTP/1.1\r\n'
              'Host: $host\r\n'
              'User-Agent: ArcaneDispatch/1.0\r\n'
              'Connection: close\r\n'
              'Accept: */*\r\n'
              '\r\n'
          .codeUnits,
    );
    await socket.flush();
    List<int> raw = <int>[];
    int cap = 4096;
    await for (List<int> chunk in socket.timeout(timeout)) {
      int remaining = cap - raw.length;
      if (remaining <= 0) break;
      if (chunk.length <= remaining) {
        raw.addAll(chunk);
      } else {
        raw.addAll(chunk.sublist(0, remaining));
        break;
      }
    }
    return parseHttpResponse(raw, now);
  } on TimeoutException {
    return CaptivePortalProbeOutcome(
      result: CaptivePortalProbeResult.error,
      capturedAt: now,
      error: 'timeout',
    );
  } catch (e) {
    return CaptivePortalProbeOutcome(
      result: CaptivePortalProbeResult.error,
      capturedAt: now,
      error: e.toString(),
    );
  } finally {
    socket?.destroy();
  }
}

/// Parses a raw HTTP response (status line + headers + body) and runs
/// it through [classifyCaptiveResponse]. Exposed for tests so we can
/// feed canned bytes through the same parser the real probe uses.
CaptivePortalProbeOutcome parseHttpResponse(List<int> raw, DateTime now) {
  String text = String.fromCharCodes(raw);
  int headerEnd = text.indexOf('\r\n\r\n');
  if (headerEnd < 0) {
    return CaptivePortalProbeOutcome(
      result: CaptivePortalProbeResult.error,
      capturedAt: now,
      error: 'malformed http response',
    );
  }
  String headers = text.substring(0, headerEnd);
  String body = text.substring(headerEnd + 4);
  int firstLineEnd = headers.indexOf('\r\n');
  String statusLine =
      firstLineEnd < 0 ? headers : headers.substring(0, firstLineEnd);
  // Status line is "HTTP/1.x CODE REASON".
  List<String> parts = statusLine.split(' ');
  int? code;
  if (parts.length >= 2) {
    code = int.tryParse(parts[1]);
  }
  return classifyCaptiveResponse(
    statusCode: code ?? 0,
    body: body,
    now: now,
  );
}

/// Classify a probe response by status code + body. Exposed for tests so
/// they can run the classification logic without standing up a real
/// HTTP server.
///
/// Rules:
/// * `200` + body contains the marker → `pass`.
/// * Any 2xx without the marker → `captive` (transparent proxy injecting
///   HTML).
/// * Any 3xx → `captive` (redirect to portal).
/// * 4xx/5xx → `error` (portal misbehaving counts as error, not captive,
///   since we don't know who served it).
CaptivePortalProbeOutcome classifyCaptiveResponse({
  required int statusCode,
  required String body,
  required DateTime now,
}) {
  if (statusCode == 200 && body.contains(captiveAppleSuccessMarker)) {
    return CaptivePortalProbeOutcome(
      result: CaptivePortalProbeResult.pass,
      capturedAt: now,
      statusCode: statusCode,
    );
  }
  if (statusCode >= 200 && statusCode < 400) {
    return CaptivePortalProbeOutcome(
      result: CaptivePortalProbeResult.captive,
      capturedAt: now,
      statusCode: statusCode,
    );
  }
  return CaptivePortalProbeOutcome(
    result: CaptivePortalProbeResult.error,
    capturedAt: now,
    statusCode: statusCode,
    error: 'http $statusCode',
  );
}

/// Resolves a [Link] to its bind source address. Returning `null` means
/// "don't pin to a specific interface" — the probe falls back to whatever
/// the default route uses. Mirrors the signature used by `LinkProbe` so
/// callers can reuse a single resolver.
typedef CaptiveSourceResolver = InternetAddress? Function(Link link);

/// Configuration knobs for [CaptivePortalDetector]. Exposed so tests can
/// drive the state machine with deterministic timings.
class CaptivePortalDetectorConfig {
  /// How often we probe while the link is in `pass` or `unknown`. Default
  /// 30 s — captive portals are sticky enough that polling faster wastes
  /// battery; the supervisor's per-link latency probe catches a sudden
  /// outage almost immediately anyway.
  final Duration normalInterval;

  /// How often we probe once a link is classified `captive`. Slower so
  /// we don't hammer the portal page. Default 60 s.
  final Duration capturedInterval;

  /// How often we probe after `error` — same as `normalInterval` so we
  /// recover quickly when the link comes back. Default 30 s.
  final Duration errorInterval;

  /// Per-probe timeout. Default 5 s.
  final Duration probeTimeout;

  /// Number of consecutive identical outcomes required to flip the
  /// state machine. Defaults to 1 (single-shot, exactly like Apple's
  /// implementation). Bumping to 2 reduces false positives at the cost of
  /// taking ~30 s extra to detect a portal.
  final int debounceCount;

  const CaptivePortalDetectorConfig({
    this.normalInterval = const Duration(seconds: 30),
    this.capturedInterval = const Duration(seconds: 60),
    this.errorInterval = const Duration(seconds: 30),
    this.probeTimeout = const Duration(seconds: 5),
    this.debounceCount = 1,
  });
}

/// State machine that decides whether a link is captive based on a
/// sequence of probe outcomes. Used by the [CaptivePortalDetector]
/// internally and exposed so tests can drive transitions directly.
class CaptivePortalState {
  /// Most recent classification. `null` until the first probe lands.
  CaptivePortalProbeResult? lastResult;

  /// Currently-debounced "candidate" result — set when we've seen one
  /// match but haven't crossed [CaptivePortalDetectorConfig.debounceCount]
  /// yet.
  CaptivePortalProbeResult? candidate;

  /// Number of consecutive observations of [candidate].
  int candidateCount = 0;

  /// Effective state surfaced to the rest of the system. Differs from
  /// [lastResult] only during debounce: when `debounceCount` is > 1, we
  /// keep reporting the previous stable state until we've seen enough
  /// matches.
  CaptivePortalProbeResult? effective;

  /// Wall-clock of the last probe.
  DateTime? lastObservedAt;

  /// Update with a new outcome and the configured debounce count.
  /// Returns true iff [effective] changed as a result.
  bool observe(CaptivePortalProbeOutcome outcome, int debounceCount) {
    lastResult = outcome.result;
    lastObservedAt = outcome.capturedAt;
    if (candidate == outcome.result) {
      candidateCount += 1;
    } else {
      candidate = outcome.result;
      candidateCount = 1;
    }
    if (candidateCount >= debounceCount && effective != candidate) {
      effective = candidate;
      return true;
    }
    return false;
  }
}

/// Per-link captive portal detector. Runs a periodic [CaptivePortalProbeFn]
/// and emits a stream of [CaptivePortalState] snapshots whenever the
/// effective state changes. The [DispatchController] subscribes and
/// re-evaluates link priorities accordingly.
///
/// Lifecycle:
///   - `start()` is idempotent. Begins ticking immediately.
///   - `cancelTimer()` is the synchronous teardown path used by tests
///     (mirrors the same idiom as `LinkProbe`).
///   - `stop()` is the async teardown path; closes the broadcast stream.
class CaptivePortalDetector {
  final Link link;
  final CaptivePortalDetectorConfig config;
  final CaptivePortalProbeFn _probe;
  final InternetAddress? Function() _resolveSource;
  final DateTime Function() _now;

  CaptivePortalState state = CaptivePortalState();
  final StreamController<CaptivePortalState> _ctrl =
      StreamController<CaptivePortalState>.broadcast();
  Timer? _timer;
  bool _stopped = false;
  Uri probeTarget;

  CaptivePortalDetector({
    required this.link,
    required InternetAddress? Function() resolveSource,
    this.config = const CaptivePortalDetectorConfig(),
    CaptivePortalProbeFn? probe,
    DateTime Function()? now,
    Uri? target,
  })  : _probe = probe ?? httpCaptivePortalProbe,
        _resolveSource = resolveSource,
        _now = now ?? DateTime.now,
        probeTarget = target ?? appleCaptiveProbeUri;

  /// Live stream of state snapshots — only emits when [effective]
  /// changes. The detector also emits the very first observation
  /// (from `unknown` to `pass`/`captive`/`error`) so subscribers learn
  /// initial state without polling [state].
  Stream<CaptivePortalState> get stream {
    return _ctrl.stream;
  }

  /// Begin the periodic probe loop. Fires one immediate tick.
  void start() {
    if (_timer != null || _stopped) return;
    unawaited(_tick());
    _schedule();
  }

  void _schedule() {
    Duration interval;
    switch (state.effective) {
      case CaptivePortalProbeResult.captive:
        interval = config.capturedInterval;
      case CaptivePortalProbeResult.error:
        interval = config.errorInterval;
      case CaptivePortalProbeResult.pass:
      case null:
        interval = config.normalInterval;
    }
    _timer?.cancel();
    _timer = Timer.periodic(interval, (Timer _) {
      unawaited(_tick());
    });
  }

  /// Synchronously stop the periodic timer. Used by tests + dispose
  /// paths that need to release the timer immediately.
  void cancelTimer() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Async teardown. Cancels the timer and closes the broadcast stream.
  Future<void> stop() async {
    cancelTimer();
    if (!_ctrl.isClosed) {
      await _ctrl.close();
    }
  }

  Future<void> _tick() async {
    if (_stopped) return;
    InternetAddress? source = _resolveSource();
    CaptivePortalProbeOutcome outcome;
    try {
      outcome = await _probe(
        target: probeTarget,
        sourceAddress: source,
        timeout: config.probeTimeout,
        now: _now(),
      );
    } catch (e) {
      outcome = CaptivePortalProbeOutcome(
        result: CaptivePortalProbeResult.error,
        capturedAt: _now(),
        error: e.toString(),
      );
    }
    bool changed = state.observe(outcome, config.debounceCount);
    if (changed) {
      _schedule();
      if (!_ctrl.isClosed) {
        _ctrl.add(state);
      }
    } else if (state.effective != null && state.candidateCount == 1) {
      // Always emit the first stable observation so subscribers don't
      // sit waiting through the initial probe.
      if (!_ctrl.isClosed) {
        _ctrl.add(state);
      }
    }
  }
}
