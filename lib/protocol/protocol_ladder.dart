// Auto protocol switch for the bonded relay transport.
//
// Each link negotiates one of:
//   * UDP / 4430 (preferred — lowest overhead, natural fit for the bonded
//     framer which is already datagram-shaped).
//   * TCP / 4430 (carriers that block UDP egress still let TCP
//     through; the bonded frame is length-prefixed so it tunnels fine).
//   * TLS / 443 with an HTTP/1.1 `Upgrade` (DPI middleboxes that intercept
//     port 443 and only allow valid TLS).
//
// The ladder is *per-link* — the bonded scheduler doesn't know which
// transport each link uses, only that `sendOnLink(linkId, bytes)` works.
// Mirrored on the Swift side by
// `macos/ArcaneDispatchTunnel/Bonded/ProtocolLadder.swift` and on the
// Go side by the relay accepting all three protocols. The Dart side is
// the authoritative test-bench because the Flutter unit test framework
// is the fastest place to lock the ordering + timeout invariants.

import 'dart:async';
import 'dart:typed_data';

/// Each rung in the ladder.
enum LinkProtocol {
  /// UDP / 443. Preferred — bonded frames are already datagram-shaped.
  udp443,

  /// TCP / 443. Length-prefixed framing. Fallback when UDP is dropped.
  tcp443,

  /// TLS-on-443 with an HTTP/1.1 `Upgrade: arcane-bonded/1` handshake.
  /// Last-resort tunnel through DPI middleboxes that strip non-TLS
  /// traffic on port 443.
  tls443,
}

extension LinkProtocolCodec on LinkProtocol {
  /// Stable wire / JSON name. Lower-snake_case keeps it humans-readable
  /// without leaking the Dart enum into UIs that pin it to specific
  /// strings.
  String get wireName {
    switch (this) {
      case LinkProtocol.udp443:
        return 'udp443';
      case LinkProtocol.tcp443:
        return 'tcp443';
      case LinkProtocol.tls443:
        return 'tls443';
    }
  }

  static LinkProtocol parse(String s) {
    switch (s) {
      case 'udp443':
        return LinkProtocol.udp443;
      case 'tcp443':
        return LinkProtocol.tcp443;
      case 'tls443':
        return LinkProtocol.tls443;
    }
    // Be lenient: bad input falls back to the preferred rung so a typo
    // in policy.json doesn't disable the tunnel.
    return LinkProtocol.udp443;
  }
}

/// Outcome of a single rung attempt. Either we got a working session
/// (the caller can keep using it), or we have a failure reason worth
/// logging.
class ProbeResult {
  /// Negotiated protocol when [transport] is non-null, otherwise the
  /// protocol that *failed* (so the UI can show "tried UDP, failed").
  final LinkProtocol protocol;

  /// Working transport if the probe succeeded. Caller takes ownership
  /// (closes it on session teardown or on a later renegotiation).
  final LinkProtocolTransport? transport;

  /// Reason the probe failed. Null on success. Free-form short string,
  /// fed straight into the UI ("connection refused", "timed out",
  /// "tls handshake failed").
  final String? failureReason;

  /// Wall time the probe took, end-to-end.
  final Duration elapsed;

  const ProbeResult({
    required this.protocol,
    required this.elapsed,
    this.transport,
    this.failureReason,
  });

  bool get isSuccess => transport != null;

  /// Helper: synth a failure result without a transport.
  factory ProbeResult.failed({
    required LinkProtocol protocol,
    required String reason,
    required Duration elapsed,
  }) {
    return ProbeResult(
      protocol: protocol,
      elapsed: elapsed,
      failureReason: reason,
    );
  }
}

/// Abstract "an open, writable channel to the relay on this protocol".
/// Real implementations live in the platform-specific layer (Swift
/// extension for macOS, eventually a `dart:io` Socket-based version for
/// other platforms).
///
/// The unit test bench injects a fake here so the ladder logic is
/// testable without booking real sockets.
abstract class LinkProtocolTransport {
  /// Which rung this transport implements.
  LinkProtocol get protocol;

  /// True once [close] has been called (or the underlying socket has
  /// died on its own).
  bool get isClosed;

  /// Push wire bytes through. Returns `true` if the send was queued for
  /// the network, `false` if the transport has already failed (caller
  /// should re-negotiate the ladder).
  bool send(Uint8List bytes);

  /// Stream of inbound wire bytes from the server. The bonded session
  /// pipes these into `BondedSession.onInboundBytes`.
  Stream<Uint8List> get inbound;

  /// Shut the transport down cleanly. Idempotent.
  Future<void> close();
}

/// Per-rung probe contract. The ladder calls [open] in order until one
/// returns a working transport (or every rung has failed).
typedef LinkProtocolProbe = Future<ProbeResult> Function();

/// Snapshot of what the ladder picked. Surfaced to the UI's per-link
/// chip and to the bonded session's metric stream.
class LinkProtocolDecision {
  final LinkProtocol chosen;

  /// Rungs we tried before [chosen]. Empty when the first rung worked.
  final List<LinkProtocol> rejected;

  /// Total time the ladder took, including failed rungs.
  final Duration totalElapsed;

  const LinkProtocolDecision({
    required this.chosen,
    required this.rejected,
    required this.totalElapsed,
  });
}

/// Sequential try-with-timeout. Walks the ladder in order, returns the
/// first rung that succeeds, or `null` when every rung fails.
///
/// Not stateful — the same instance can run multiple negotiations
/// concurrently for different links. The probes themselves carry any
/// per-link config.
class ProtocolLadder {
  /// Ordered list of rungs to try. Defaults to UDP → TCP → TLS, which
  /// is the canonical Speedify-style ordering.
  final List<LinkProtocol> ordering;

  /// Per-rung timeout. Hit this before declaring the rung dead so we
  /// don't sit forever on a black-holed UDP path.
  final Duration perStepTimeout;

  const ProtocolLadder({
    this.ordering = const <LinkProtocol>[
      LinkProtocol.udp443,
      LinkProtocol.tcp443,
      LinkProtocol.tls443,
    ],
    this.perStepTimeout = const Duration(seconds: 5),
  });

  /// Negotiate. [probeFor] returns the open future for a given rung —
  /// the caller wires this to its real (or fake) socket factory.
  /// Returns `null` when every rung fails.
  ///
  /// On success the working transport is in `result.transport` and is
  /// the caller's responsibility to close.
  Future<LadderResult> negotiate(
    LinkProtocolProbe Function(LinkProtocol) probeFor,
  ) async {
    Stopwatch sw = Stopwatch()..start();
    List<ProbeResult> attempts = <ProbeResult>[];
    for (LinkProtocol p in ordering) {
      LinkProtocolProbe probe = probeFor(p);
      ProbeResult r = await _runWithTimeout(probe, p);
      attempts.add(r);
      if (r.isSuccess) {
        return LadderResult(
          chosen: r,
          attempts: attempts,
          totalElapsed: sw.elapsed,
        );
      }
    }
    return LadderResult(
      chosen: null,
      attempts: attempts,
      totalElapsed: sw.elapsed,
    );
  }

  /// Single-rung helper exposed for tests that want to drive one probe
  /// in isolation (e.g. a "what if we re-probe UDP after recovery"
  /// scenario).
  Future<ProbeResult> tryStep(LinkProtocol p, LinkProtocolProbe probe) {
    return _runWithTimeout(probe, p);
  }

  Future<ProbeResult> _runWithTimeout(
    LinkProtocolProbe probe,
    LinkProtocol expected,
  ) async {
    Stopwatch local = Stopwatch()..start();
    try {
      ProbeResult r = await probe().timeout(perStepTimeout);
      return r;
    } on TimeoutException {
      return ProbeResult.failed(
        protocol: expected,
        reason: 'timed out after ${perStepTimeout.inMilliseconds}ms',
        elapsed: local.elapsed,
      );
    } catch (e) {
      return ProbeResult.failed(
        protocol: expected,
        reason: e.toString(),
        elapsed: local.elapsed,
      );
    }
  }
}

/// Bundle returned by [ProtocolLadder.negotiate].
class LadderResult {
  /// Successful rung. Null when every rung failed.
  final ProbeResult? chosen;

  /// Every attempt, in order. Last entry is the same as [chosen] on
  /// success; on failure every entry is a failed attempt.
  final List<ProbeResult> attempts;

  /// Wall time the entire negotiation took.
  final Duration totalElapsed;

  const LadderResult({
    required this.chosen,
    required this.attempts,
    required this.totalElapsed,
  });

  bool get isSuccess => chosen?.isSuccess ?? false;

  /// Convert to the snapshot the UI / metric stream want.
  LinkProtocolDecision toDecision() {
    if (!isSuccess) {
      // Caller should normally only call this on success. Provide a
      // sensible fallback (chose nothing, all rungs rejected) so the
      // UI doesn't crash.
      List<LinkProtocol> rejected = attempts
          .map((ProbeResult r) => r.protocol)
          .toList();
      return LinkProtocolDecision(
        chosen: rejected.isNotEmpty ? rejected.last : LinkProtocol.udp443,
        rejected: rejected,
        totalElapsed: totalElapsed,
      );
    }
    List<LinkProtocol> rejected = <LinkProtocol>[];
    for (ProbeResult r in attempts) {
      if (!r.isSuccess) {
        rejected.add(r.protocol);
      }
    }
    return LinkProtocolDecision(
      chosen: chosen!.protocol,
      rejected: rejected,
      totalElapsed: totalElapsed,
    );
  }
}
