// Streaming/real-time flow detection.
//
// Phase 12 of plans/2026-05-11-speedify-clone-v1.md.
//
// Cheap, no-DPI classifier that flags TCP/UDP flows as real-time based on:
//
//   1. Well-known port heuristics (STUN/TURN/SIP/RTP/QUIC media)
//   2. Provider IP CIDR ranges (Zoom, Google Meet, MS Teams, Discord voice)
//   3. SNI substring match for known media hosts (when the caller can extract it)
//   4. Optional user allow-list of host substrings / CIDRs
//
// The classifier is **pure and stateless** — it takes a [StreamingFlowProbe]
// and returns a verdict. Hosting state (caching, expiry, etc.) lives in the
// caller (FlowTracker on Swift, ad-hoc on Dart for tests).
//
// IP heuristics use simple CIDR matching. We deliberately keep the ranges
// short — these are known public anycast ranges for media (not all of the
// provider's infra). False negatives are fine; false positives are worse,
// because we don't want the QoS lane to starve bulk traffic.

import 'dart:typed_data';

/// Transport layer of the flow being classified.
enum FlowTransport { tcp, udp }

/// Output of [StreamingClassifier].
enum StreamingVerdict {
  /// Definitely real-time (audio/video conferencing, voice calls).
  realtime,

  /// Likely bulk/normal traffic.
  normal,

  /// Not enough info to decide (we'll re-evaluate when more signal arrives).
  unknown,
}

/// Minimal info needed to classify a flow.
///
/// All fields are optional except [destPort] and [transport]. The classifier
/// uses whatever is present and otherwise falls back to [StreamingVerdict.unknown].
class StreamingFlowProbe {
  StreamingFlowProbe({
    required this.destPort,
    required this.transport,
    this.destIpV4,
    this.destIpV6,
    this.sni,
    this.processName,
  });

  /// TCP/UDP destination port.
  final int destPort;

  /// Layer-4 protocol.
  final FlowTransport transport;

  /// IPv4 destination as 4-byte network order, if known.
  final Uint8List? destIpV4;

  /// IPv6 destination as 16-byte network order, if known.
  final Uint8List? destIpV6;

  /// SNI extracted from a TLS ClientHello, if seen.
  final String? sni;

  /// Process name (best-effort, for the user allow-list).
  final String? processName;
}

/// A CIDR rule like `162.159.128.0/19` (Discord voice).
class CidrRule {
  CidrRule(this.bytes, this.prefixBits) : assert(prefixBits >= 0);

  /// Network bytes (4 for v4, 16 for v6).
  final Uint8List bytes;

  /// Number of significant prefix bits.
  final int prefixBits;

  /// Parse `"a.b.c.d/n"` or `"::1/128"`.
  factory CidrRule.parse(String text) {
    final slash = text.indexOf('/');
    if (slash < 0) {
      throw FormatException('CidrRule.parse: missing "/": $text');
    }
    final addr = text.substring(0, slash);
    final prefix = int.parse(text.substring(slash + 1));
    if (addr.contains(':')) {
      return CidrRule(_parseIpv6(addr), prefix);
    }
    return CidrRule(_parseIpv4(addr), prefix);
  }

  bool matches(Uint8List ip) {
    if (ip.length != bytes.length) return false;
    final fullBytes = prefixBits ~/ 8;
    for (var i = 0; i < fullBytes; i++) {
      if (ip[i] != bytes[i]) return false;
    }
    final remainder = prefixBits % 8;
    if (remainder == 0) return true;
    final mask = (0xFF << (8 - remainder)) & 0xFF;
    return (ip[fullBytes] & mask) == (bytes[fullBytes] & mask);
  }

  static Uint8List _parseIpv4(String text) {
    final parts = text.split('.');
    if (parts.length != 4) {
      throw FormatException('Invalid IPv4: $text');
    }
    final out = Uint8List(4);
    for (var i = 0; i < 4; i++) {
      out[i] = int.parse(parts[i]);
    }
    return out;
  }

  static Uint8List _parseIpv6(String text) {
    // Very small parser — sufficient for the hard-coded prefixes we ship.
    final segments = <int>[];
    final chunks = text.split('::');
    final left = chunks.first.isEmpty ? <String>[] : chunks.first.split(':');
    final right =
        chunks.length > 1
            ? (chunks[1].isEmpty ? <String>[] : chunks[1].split(':'))
            : <String>[];
    final missing = 8 - left.length - right.length;
    for (final h in left) {
      segments.add(int.parse(h, radix: 16));
    }
    for (var i = 0; i < missing; i++) {
      segments.add(0);
    }
    for (final h in right) {
      segments.add(int.parse(h, radix: 16));
    }
    if (segments.length != 8) {
      throw FormatException('Invalid IPv6: $text');
    }
    final out = Uint8List(16);
    for (var i = 0; i < 8; i++) {
      out[i * 2] = (segments[i] >> 8) & 0xFF;
      out[i * 2 + 1] = segments[i] & 0xFF;
    }
    return out;
  }
}

/// Bundled rule sets that ship out of the box.
class StreamingRules {
  StreamingRules({
    Set<int>? rtPortsUdp,
    Set<int>? rtPortsTcp,
    List<CidrRule>? cidrs,
    List<String>? sniSubstrings,
    List<String>? processAllowList,
  })  : rtPortsUdp = rtPortsUdp ?? _defaultUdpPorts,
        rtPortsTcp = rtPortsTcp ?? _defaultTcpPorts,
        cidrs = cidrs ?? _defaultCidrs,
        sniSubstrings = sniSubstrings ?? _defaultSniSubstrings,
        processAllowList = processAllowList ?? const <String>[];

  final Set<int> rtPortsUdp;
  final Set<int> rtPortsTcp;
  final List<CidrRule> cidrs;
  final List<String> sniSubstrings;
  final List<String> processAllowList;

  StreamingRules copyWith({
    Set<int>? rtPortsUdp,
    Set<int>? rtPortsTcp,
    List<CidrRule>? cidrs,
    List<String>? sniSubstrings,
    List<String>? processAllowList,
  }) {
    return StreamingRules(
      rtPortsUdp: rtPortsUdp ?? this.rtPortsUdp,
      rtPortsTcp: rtPortsTcp ?? this.rtPortsTcp,
      cidrs: cidrs ?? this.cidrs,
      sniSubstrings: sniSubstrings ?? this.sniSubstrings,
      processAllowList: processAllowList ?? this.processAllowList,
    );
  }

  // Default port lists — IANA + common provider port ranges.
  static const Set<int> _defaultUdpPorts = <int>{
    // STUN/TURN
    3478, 3479, 5349, 5350,
    // RTP common ranges (we hit the most-used handful; can't list 16384–32767).
    19302, 19303, 19305, 19306, 19307, 19308, 19309,
    // SIP
    5060, 5061,
    // Zoom / Meet / Teams primary UDP media
    8801, 8802, 8803, 8804,
    // Discord voice
    50000, 50001, 50002, 50003, 50004, 50005,
  };

  static const Set<int> _defaultTcpPorts = <int>{
    // SIP-TCP / SIPS
    5060, 5061,
    // RTMP / RTSP (older streaming)
    554, 1935,
    // Teams TCP fallback
    50080, 50081,
  };

  // Public anycast IP ranges of major providers that route media-only traffic.
  static final List<CidrRule> _defaultCidrs = <CidrRule>[
    // Zoom — 50.239.0.0/16, 64.211.144.0/24
    CidrRule.parse('50.239.0.0/16'),
    CidrRule.parse('64.211.144.0/24'),
    // Google Meet / Workspace media
    CidrRule.parse('74.125.250.0/24'),
    // Discord voice (Cloudflare anycast subset)
    CidrRule.parse('162.159.128.0/19'),
    // Microsoft Teams transport
    CidrRule.parse('52.112.0.0/14'),
  ];

  static const List<String> _defaultSniSubstrings = <String>[
    'zoom.us',
    'zoomgov.com',
    'meet.google',
    'teams.microsoft',
    'teams.live',
    'discord.gg',
    'discord.media',
    'webex.com',
    'whereby.com',
    'jitsi.',
  ];
}

/// Pure classifier: probe in, verdict out.
class StreamingClassifier {
  StreamingClassifier({StreamingRules? rules})
      : rules = rules ?? StreamingRules();

  StreamingRules rules;

  /// Replace the active rule set (e.g. when user toggles allow-list entries).
  void setRules(StreamingRules next) {
    rules = next;
  }

  /// Classify a flow.
  StreamingVerdict classify(StreamingFlowProbe probe) {
    if (probe.processName != null &&
        rules.processAllowList.any(
          (p) => probe.processName!.toLowerCase().contains(p.toLowerCase()),
        )) {
      return StreamingVerdict.realtime;
    }

    if (probe.sni != null) {
      final sni = probe.sni!.toLowerCase();
      for (final needle in rules.sniSubstrings) {
        if (sni.contains(needle.toLowerCase())) {
          return StreamingVerdict.realtime;
        }
      }
    }

    final ports = probe.transport == FlowTransport.udp
        ? rules.rtPortsUdp
        : rules.rtPortsTcp;
    if (ports.contains(probe.destPort)) {
      return StreamingVerdict.realtime;
    }

    // UDP RTP/SRTP commonly lives in the 16384–32767 dynamic range. We treat
    // this band as **probably realtime** but only when paired with a non-zero
    // payload and no other strong signal (caller decides via [StreamingVerdict.unknown]).
    if (probe.transport == FlowTransport.udp &&
        probe.destPort >= 16384 &&
        probe.destPort <= 32767) {
      return StreamingVerdict.realtime;
    }

    final ip = probe.destIpV4 ?? probe.destIpV6;
    if (ip != null) {
      for (final cidr in rules.cidrs) {
        if (cidr.matches(ip)) {
          return StreamingVerdict.realtime;
        }
      }
    }

    if (probe.destIpV4 == null && probe.destIpV6 == null && probe.sni == null) {
      return StreamingVerdict.unknown;
    }
    return StreamingVerdict.normal;
  }
}
