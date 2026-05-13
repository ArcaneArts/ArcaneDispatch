// In-process bonded loopback harness.
//
// Wires a client [BondedSession] and a server [BondedSession] together
// through N pure-Dart "virtual links" that simulate per-link RTT and loss.
// No real sockets are touched — this is a deterministic test bench so we
// can validate striping + reassembly without booking real loopback ports.
//
// Used by `test/bonded/local_bonded_loopback_test.dart` and by anyone
// debugging the bonded protocol locally before running on real hardware.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/bonding_mode.dart';
import 'bonded_scheduler.dart';
import 'bonded_session.dart';

/// Tunables for a single simulated link.
class VirtualLinkSpec {
  /// Stable identifier, matches `Link.id`.
  final String linkId;

  /// Wire id stamped into bonded frames (the protocol's u16 linkId field).
  final int wireId;

  /// One-way latency in milliseconds. We schedule [Timer] callbacks
  /// `latencyMs` from now to simulate transit; the test bench freezes time
  /// via fake async.
  final int latencyMs;

  /// Loss probability per packet (0.0–1.0). A roll greater than `loss`
  /// passes; anything else gets quietly dropped.
  final double loss;

  /// Bandwidth hint surfaced to the scheduler so the Speed-mode credit
  /// formula has something realistic to chew on. Bytes/sec.
  final double bandwidthBps;

  const VirtualLinkSpec({
    required this.linkId,
    required this.wireId,
    this.latencyMs = 25,
    this.loss = 0.0,
    this.bandwidthBps = 5_000_000.0,
  });
}

/// Two [BondedSession]s linked by [VirtualLinkSpec]s. The client sends, the
/// server reassembles.
class LocalBondedLoopback {
  final List<VirtualLinkSpec> links;
  final int clientSessionId;
  final int serverSessionId;
  final math.Random rng;

  /// Optional seal/open pairs. When both sides have both hooks wired, the
  /// loopback exercises the Phase 9 sealed-frame envelope path:
  /// client `sealer` is applied before delivery, server `opener` is
  /// applied on receive (and vice-versa for the reverse direction).
  final BondedFrameSealer? clientSealer;
  final BondedFrameOpener? clientOpener;
  final BondedFrameSealer? serverSealer;
  final BondedFrameOpener? serverOpener;

  late final BondedSession client;
  late final BondedSession server;
  final List<Uint8List> serverReceived = <Uint8List>[];
  StreamSubscription<Uint8List>? _serverOutboundSub;

  /// Packets each direction has dropped due to the loss model. Useful for
  /// asserting "no NAK storm" in clean-link tests.
  int clientPacketsDropped = 0;
  int serverPacketsDropped = 0;

  LocalBondedLoopback({
    required this.links,
    this.clientSessionId = 0xABCD000000000001,
    this.serverSessionId = 0xABCD000000000001,
    math.Random? random,
    this.clientSealer,
    this.clientOpener,
    this.serverSealer,
    this.serverOpener,
  }) : rng = random ?? math.Random(0xC0FFEE) {
    assert(links.isNotEmpty);
  }

  void start({
    Duration keepaliveInterval = const Duration(seconds: 1),
    Duration reassemblerGapTimeout = const Duration(milliseconds: 80),
    int reassemblerWindowSize = 4096,
    BondingMode mode = BondingMode.speed,
  }) {
    // Build both sessions. They share the same wire sessionId (the harness
    // doesn't model a server with multiple clients yet).
    client = BondedSession(
      config: BondedSessionConfig(
        sessionId: clientSessionId,
        mode: mode,
        keepaliveInterval: keepaliveInterval,
        reassemblerGapTimeout: reassemblerGapTimeout,
        reassemblerWindowSize: reassemblerWindowSize,
      ),
      sendOnLink: _clientSendOnLink,
      sealer: clientSealer,
      opener: clientOpener,
    );
    server = BondedSession(
      config: BondedSessionConfig(
        sessionId: serverSessionId,
        mode: mode,
        keepaliveInterval: keepaliveInterval,
        reassemblerGapTimeout: reassemblerGapTimeout,
        reassemblerWindowSize: reassemblerWindowSize,
      ),
      sendOnLink: _serverSendOnLink,
      sealer: serverSealer,
      opener: serverOpener,
    );

    // Set up scheduler state on both ends from the link specs.
    List<BondedLinkState> states = links
        .map(
          (VirtualLinkSpec spec) => BondedLinkState(
            linkId: spec.linkId,
            wireId: spec.wireId,
            bandwidthBps: spec.bandwidthBps,
            rttMs: spec.latencyMs.toDouble() * 2.0,
            lossFraction: spec.loss,
          ),
        )
        .toList();
    client.scheduler.updateLinks(states);
    server.scheduler.updateLinks(states);

    client.start();
    server.start();
    _serverOutboundSub = server.reassembler.outbound.listen(serverReceived.add);
  }

  /// Convenience for the test: send N copies of `chunk` and wait for the
  /// server to reassemble them all (or for [timeout] to expire).
  Future<void> waitForServerBytes(
    int bytes, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      int received = 0;
      for (Uint8List b in serverReceived) {
        received += b.length;
      }
      if (received >= bytes) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> dispose() async {
    await _serverOutboundSub?.cancel();
    await client.dispose();
    await server.dispose();
  }

  // ---------------------------------------------------------------------
  // internals
  // ---------------------------------------------------------------------

  void _clientSendOnLink(String linkId, Uint8List bytes) {
    VirtualLinkSpec spec = _specFor(linkId);
    int payloadLen = bytes.length > 24 ? bytes.length - 24 : 0;
    if (_rollLoss(spec)) {
      clientPacketsDropped++;
      // Real ACKs would never arrive, but real TCP would retransmit. For
      // scheduler credit accounting we model "we tried, the bytes are gone"
      // by freeing inflight after a short delay — the test exercises NAK
      // retransmits, not credit famine.
      Timer(Duration(milliseconds: spec.latencyMs * 2), () {
        client.scheduler.completeSend(linkId, payloadLen);
      });
      return;
    }
    Timer(Duration(milliseconds: spec.latencyMs), () {
      _deliverToServer(bytes);
      // Synthetic ACK: assume the receiver accepted the bytes, free the
      // scheduler's inflight counter so the next pick sees real credit.
      client.scheduler.completeSend(linkId, payloadLen);
    });
  }

  void _serverSendOnLink(String linkId, Uint8List bytes) {
    VirtualLinkSpec spec = _specFor(linkId);
    int payloadLen = bytes.length > 24 ? bytes.length - 24 : 0;
    if (_rollLoss(spec)) {
      serverPacketsDropped++;
      Timer(Duration(milliseconds: spec.latencyMs * 2), () {
        server.scheduler.completeSend(linkId, payloadLen);
      });
      return;
    }
    Timer(Duration(milliseconds: spec.latencyMs), () {
      _deliverToClient(bytes);
      server.scheduler.completeSend(linkId, payloadLen);
    });
  }

  void _deliverToServer(Uint8List bytes) {
    // Use onInboundBytes so the sealing/opening path is exercised when
    // wired. Without an opener it falls through to plain decodeBondedFrame.
    server.onInboundBytes(bytes);
  }

  void _deliverToClient(Uint8List bytes) {
    client.onInboundBytes(bytes);
  }

  VirtualLinkSpec _specFor(String linkId) {
    for (VirtualLinkSpec spec in links) {
      if (spec.linkId == linkId) return spec;
    }
    // Unknown link — shouldn't happen because we initialize from `links`.
    return links.first;
  }

  bool _rollLoss(VirtualLinkSpec spec) {
    if (spec.loss <= 0.0) return false;
    if (spec.loss >= 1.0) return true;
    return rng.nextDouble() < spec.loss;
  }
}

/// Helper for tests: snapshot of who sent how many bytes / packets where.
class LoopbackTelemetry {
  final BondedSessionStats client;
  final BondedSessionStats server;
  final int clientPacketsDropped;
  final int serverPacketsDropped;

  LoopbackTelemetry({
    required this.client,
    required this.server,
    required this.clientPacketsDropped,
    required this.serverPacketsDropped,
  });

  factory LoopbackTelemetry.from(LocalBondedLoopback loopback) {
    return LoopbackTelemetry(
      client: loopback.client.snapshot(),
      server: loopback.server.snapshot(),
      clientPacketsDropped: loopback.clientPacketsDropped,
      serverPacketsDropped: loopback.serverPacketsDropped,
    );
  }
}

/// Convenience wrapper that reassembles all of [serverReceived] into a
/// single byte buffer for equality checks.
Uint8List joinReceived(List<Uint8List> chunks) {
  int total = 0;
  for (Uint8List c in chunks) {
    total += c.length;
  }
  Uint8List out = Uint8List(total);
  int offset = 0;
  for (Uint8List c in chunks) {
    out.setRange(offset, offset + c.length, c);
    offset += c.length;
  }
  return out;
}
