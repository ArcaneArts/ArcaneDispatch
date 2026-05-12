// Phase 14: unit tests for the captive portal probe + detector.
//
// We deliberately avoid touching the real network — `httpCaptivePortalProbe`
// is replaced with an injected fake so the state machine can be exercised
// deterministically. The parser/classifier helpers are pure functions, so
// they get the most coverage.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/core/link.dart';
import 'package:arcane_dispatch/probes/captive_portal_probe.dart';

DateTime _t0() => DateTime.utc(2026, 5, 11, 0, 0, 0);

Link _link({String id = 'wifi'}) {
  return Link(
    id: id,
    label: 'Wi-Fi',
    interfaceName: 'en0',
    sourceAddress: '192.0.2.1',
    weight: 1,
  );
}

void main() {
  group('classifyCaptiveResponse', () {
    test('returns pass for 200 + canonical Apple body', () {
      String body = '<HTML>\n'
          '<HEAD><TITLE>Success</TITLE></HEAD>\n'
          '<BODY>\nSuccess\n</BODY>\n'
          '</HTML>';
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 200,
        body: body,
        now: _t0(),
      );
      expect(o.result, CaptivePortalProbeResult.pass);
      expect(o.statusCode, 200);
      expect(o.error, isNull);
      expect(o.isPass, isTrue);
      expect(o.isCaptive, isFalse);
    });

    test('returns captive for 200 without marker (transparent proxy)', () {
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 200,
        body: '<html>Please log in to use the Wi-Fi.</html>',
        now: _t0(),
      );
      expect(o.result, CaptivePortalProbeResult.captive);
      expect(o.statusCode, 200);
      expect(o.isCaptive, isTrue);
    });

    test('returns captive for 302 redirect to portal', () {
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 302,
        body: '',
        now: _t0(),
      );
      expect(o.result, CaptivePortalProbeResult.captive);
      expect(o.statusCode, 302);
    });

    test('returns error for 4xx', () {
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 403,
        body: 'forbidden',
        now: _t0(),
      );
      expect(o.result, CaptivePortalProbeResult.error);
      expect(o.statusCode, 403);
      expect(o.error, contains('403'));
    });

    test('returns error for 5xx', () {
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 502,
        body: '',
        now: _t0(),
      );
      expect(o.result, CaptivePortalProbeResult.error);
      expect(o.statusCode, 502);
    });

    test('rejects portals that put "Success" outside the title tag', () {
      // Adversarial portal returning 200 with a body that mentions the
      // word "Success" but not in `<TITLE>`. Should be classified as
      // captive, not pass.
      CaptivePortalProbeOutcome o = classifyCaptiveResponse(
        statusCode: 200,
        body: '<html><body>Login Success here later!</body></html>',
        now: _t0(),
      );
      expect(o.result, CaptivePortalProbeResult.captive);
    });
  });

  group('parseHttpResponse', () {
    test('handles a complete response with the marker', () {
      String wire = 'HTTP/1.1 200 OK\r\n'
          'Content-Type: text/html\r\n'
          'Content-Length: 70\r\n'
          '\r\n'
          '<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>';
      CaptivePortalProbeOutcome o = parseHttpResponse(wire.codeUnits, _t0());
      expect(o.result, CaptivePortalProbeResult.pass);
      expect(o.statusCode, 200);
    });

    test('returns error when there is no header terminator', () {
      String wire = 'HTTP/1.1 200 OK';
      CaptivePortalProbeOutcome o = parseHttpResponse(wire.codeUnits, _t0());
      expect(o.result, CaptivePortalProbeResult.error);
      expect(o.error, contains('malformed'));
    });

    test('handles 302 redirect', () {
      String wire = 'HTTP/1.1 302 Found\r\n'
          'Location: http://portal.example.net/login\r\n'
          'Content-Length: 0\r\n'
          '\r\n';
      CaptivePortalProbeOutcome o = parseHttpResponse(wire.codeUnits, _t0());
      expect(o.result, CaptivePortalProbeResult.captive);
      expect(o.statusCode, 302);
    });

    test('handles malformed status line as status code 0 (error)', () {
      String wire = 'NOTHTTP\r\n'
          'Content-Length: 0\r\n'
          '\r\n';
      CaptivePortalProbeOutcome o = parseHttpResponse(wire.codeUnits, _t0());
      // Empty status line → code parsed as 0 → falls into the error bucket.
      expect(o.result, CaptivePortalProbeResult.error);
    });
  });

  group('CaptivePortalState', () {
    test('first observe emits and updates effective', () {
      CaptivePortalState s = CaptivePortalState();
      bool changed = s.observe(
        CaptivePortalProbeOutcome(
          result: CaptivePortalProbeResult.pass,
          capturedAt: _t0(),
        ),
        1,
      );
      expect(changed, isTrue);
      expect(s.effective, CaptivePortalProbeResult.pass);
      expect(s.lastResult, CaptivePortalProbeResult.pass);
      expect(s.candidateCount, 1);
    });

    test('debounce of 2 requires two matching outcomes to flip', () {
      CaptivePortalState s = CaptivePortalState();
      bool c1 = s.observe(
        CaptivePortalProbeOutcome(
          result: CaptivePortalProbeResult.captive,
          capturedAt: _t0(),
        ),
        2,
      );
      expect(c1, isFalse);
      expect(s.effective, isNull);
      expect(s.candidateCount, 1);
      bool c2 = s.observe(
        CaptivePortalProbeOutcome(
          result: CaptivePortalProbeResult.captive,
          capturedAt: _t0(),
        ),
        2,
      );
      expect(c2, isTrue);
      expect(s.effective, CaptivePortalProbeResult.captive);
      expect(s.candidateCount, 2);
    });

    test('different outcomes reset the candidate counter', () {
      CaptivePortalState s = CaptivePortalState();
      s.observe(
        CaptivePortalProbeOutcome(
          result: CaptivePortalProbeResult.captive,
          capturedAt: _t0(),
        ),
        3,
      );
      s.observe(
        CaptivePortalProbeOutcome(
          result: CaptivePortalProbeResult.pass,
          capturedAt: _t0(),
        ),
        3,
      );
      expect(s.candidate, CaptivePortalProbeResult.pass);
      expect(s.candidateCount, 1);
      expect(s.effective, isNull,
          reason: '3-debounce never satisfied — effective stays unknown.');
    });
  });

  group('CaptivePortalDetector', () {
    test('emits the first stable observation and updates state', () async {
      List<CaptivePortalProbeResult> sequence = <CaptivePortalProbeResult>[
        CaptivePortalProbeResult.pass,
      ];
      int callCount = 0;
      CaptivePortalDetector det = CaptivePortalDetector(
        link: _link(),
        resolveSource: () => null,
        config: const CaptivePortalDetectorConfig(
          normalInterval: Duration(milliseconds: 50),
          probeTimeout: Duration(milliseconds: 100),
        ),
        probe: ({
          required Uri target,
          required InternetAddress? sourceAddress,
          required Duration timeout,
          required DateTime now,
        }) async {
          CaptivePortalProbeResult r = sequence[callCount % sequence.length];
          callCount += 1;
          return CaptivePortalProbeOutcome(
            result: r,
            capturedAt: now,
            statusCode: r == CaptivePortalProbeResult.pass ? 200 : 302,
          );
        },
      );

      Completer<CaptivePortalState> firstEmit = Completer<CaptivePortalState>();
      StreamSubscription<CaptivePortalState> sub = det.stream.listen((s) {
        if (!firstEmit.isCompleted) firstEmit.complete(s);
      });
      det.start();
      CaptivePortalState s = await firstEmit.future.timeout(
        const Duration(seconds: 1),
      );
      expect(s.effective, CaptivePortalProbeResult.pass);
      await sub.cancel();
      await det.stop();
    });

    test(
        'flips effective state when probe outcome changes after debounce',
        () async {
      // Alternate captive → captive → pass → pass with debounceCount: 2.
      // Effective should land on captive after the second captive and
      // flip back to pass after the second pass.
      List<CaptivePortalProbeResult> sequence = <CaptivePortalProbeResult>[
        CaptivePortalProbeResult.captive,
        CaptivePortalProbeResult.captive,
        CaptivePortalProbeResult.pass,
        CaptivePortalProbeResult.pass,
      ];
      int callCount = 0;
      CaptivePortalDetector det = CaptivePortalDetector(
        link: _link(),
        resolveSource: () => null,
        config: const CaptivePortalDetectorConfig(
          normalInterval: Duration(milliseconds: 25),
          capturedInterval: Duration(milliseconds: 25),
          errorInterval: Duration(milliseconds: 25),
          probeTimeout: Duration(milliseconds: 50),
          debounceCount: 2,
        ),
        probe: ({
          required Uri target,
          required InternetAddress? sourceAddress,
          required Duration timeout,
          required DateTime now,
        }) async {
          CaptivePortalProbeResult r = sequence[
              callCount.clamp(0, sequence.length - 1)];
          callCount += 1;
          return CaptivePortalProbeOutcome(
            result: r,
            capturedAt: now,
            statusCode: r == CaptivePortalProbeResult.pass ? 200 : 302,
          );
        },
      );

      List<CaptivePortalProbeResult?> seen = <CaptivePortalProbeResult?>[];
      StreamSubscription<CaptivePortalState> sub = det.stream.listen((s) {
        seen.add(s.effective);
      });
      det.start();
      // Allow enough wall-clock time for the 4 ticks to land.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await sub.cancel();
      await det.stop();
      expect(seen, contains(CaptivePortalProbeResult.captive));
      expect(seen, contains(CaptivePortalProbeResult.pass));
      expect(seen.last, CaptivePortalProbeResult.pass);
    });

    test('cancelTimer makes start a no-op', () async {
      CaptivePortalDetector det = CaptivePortalDetector(
        link: _link(),
        resolveSource: () => null,
        probe: ({
          required Uri target,
          required InternetAddress? sourceAddress,
          required Duration timeout,
          required DateTime now,
        }) async {
          throw StateError('probe should not run after cancelTimer');
        },
      );
      det.cancelTimer();
      // After cancelTimer the start() call must do nothing — the test
      // would explode if it did.
      det.start();
      await det.stop();
    });
  });
}
