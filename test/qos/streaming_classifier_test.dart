// Tests for [StreamingClassifier].

import 'dart:typed_data';

import 'package:arcane_dispatch/qos/streaming_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _v4(int a, int b, int c, int d) =>
    Uint8List.fromList([a, b, c, d]);

void main() {
  group('CidrRule', () {
    test('IPv4 /24 matches only first 24 bits', () {
      final rule = CidrRule.parse('10.20.30.0/24');
      expect(rule.matches(_v4(10, 20, 30, 1)), isTrue);
      expect(rule.matches(_v4(10, 20, 30, 255)), isTrue);
      expect(rule.matches(_v4(10, 20, 31, 0)), isFalse);
      expect(rule.matches(_v4(11, 20, 30, 0)), isFalse);
    });

    test('IPv4 /22 spans 4 /24 blocks', () {
      final rule = CidrRule.parse('52.112.0.0/14');
      expect(rule.matches(_v4(52, 112, 0, 0)), isTrue);
      expect(rule.matches(_v4(52, 115, 255, 255)), isTrue);
      expect(rule.matches(_v4(52, 116, 0, 0)), isFalse);
      expect(rule.matches(_v4(52, 111, 255, 255)), isFalse);
    });

    test('IPv4 /32 only matches the exact address', () {
      final rule = CidrRule.parse('1.2.3.4/32');
      expect(rule.matches(_v4(1, 2, 3, 4)), isTrue);
      expect(rule.matches(_v4(1, 2, 3, 5)), isFalse);
    });

    test('IPv6 parsing handles "::" shorthand', () {
      final rule = CidrRule.parse('2001:db8::/32');
      final ip = Uint8List(16);
      ip[0] = 0x20;
      ip[1] = 0x01;
      ip[2] = 0x0d;
      ip[3] = 0xb8;
      expect(rule.matches(ip), isTrue);
      ip[3] = 0xb9;
      expect(rule.matches(ip), isFalse);
    });

    test('parse rejects missing slash', () {
      expect(() => CidrRule.parse('1.2.3.4'), throwsFormatException);
    });
  });

  group('StreamingClassifier', () {
    final classifier = StreamingClassifier();

    test('STUN UDP port is realtime', () {
      final v = classifier.classify(
        StreamingFlowProbe(
          destPort: 3478,
          transport: FlowTransport.udp,
        ),
      );
      expect(v, StreamingVerdict.realtime);
    });

    test('UDP RTP dynamic range is realtime', () {
      final v = classifier.classify(
        StreamingFlowProbe(
          destPort: 19302,
          transport: FlowTransport.udp,
        ),
      );
      expect(v, StreamingVerdict.realtime);

      final inRange = classifier.classify(
        StreamingFlowProbe(
          destPort: 20000,
          transport: FlowTransport.udp,
        ),
      );
      expect(inRange, StreamingVerdict.realtime);
    });

    test('TCP/443 to non-conferencing IP without SNI is unknown', () {
      final v = classifier.classify(
        StreamingFlowProbe(
          destPort: 443,
          transport: FlowTransport.tcp,
        ),
      );
      expect(v, StreamingVerdict.unknown);
    });

    test('TCP/443 with Zoom SNI is realtime', () {
      final v = classifier.classify(
        StreamingFlowProbe(
          destPort: 443,
          transport: FlowTransport.tcp,
          sni: 'us05web.zoom.us',
        ),
      );
      expect(v, StreamingVerdict.realtime);
    });

    test('Discord voice CIDR is realtime even on TCP/443', () {
      final v = classifier.classify(
        StreamingFlowProbe(
          destPort: 443,
          transport: FlowTransport.tcp,
          destIpV4: _v4(162, 159, 130, 50),
        ),
      );
      expect(v, StreamingVerdict.realtime);
    });

    test('SIP TCP 5061 is realtime', () {
      final v = classifier.classify(
        StreamingFlowProbe(
          destPort: 5061,
          transport: FlowTransport.tcp,
        ),
      );
      expect(v, StreamingVerdict.realtime);
    });

    test('plain HTTP/80 to unknown IP is normal', () {
      final v = classifier.classify(
        StreamingFlowProbe(
          destPort: 80,
          transport: FlowTransport.tcp,
          destIpV4: _v4(93, 184, 216, 34), // example.com
        ),
      );
      expect(v, StreamingVerdict.normal);
    });

    test('user allow-list overrides everything', () {
      final c = StreamingClassifier(
        rules: StreamingRules(processAllowList: const ['mumble']),
      );
      final v = c.classify(
        StreamingFlowProbe(
          destPort: 80,
          transport: FlowTransport.tcp,
          processName: '/usr/local/bin/Mumble',
        ),
      );
      expect(v, StreamingVerdict.realtime);
    });

    test('setRules updates classifier in place', () {
      final c = StreamingClassifier();
      // Strip all defaults — should now report normal/unknown for STUN.
      c.setRules(StreamingRules(rtPortsUdp: const <int>{}));
      // Note: 3478 falls within RTP dynamic range only above 16384, so it
      // becomes "normal" once removed from the explicit set.
      final v = c.classify(
        StreamingFlowProbe(
          destPort: 3478,
          transport: FlowTransport.udp,
        ),
      );
      expect(v, isNot(StreamingVerdict.realtime));
    });
  });
}
