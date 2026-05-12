// End-to-end stripe + reassemble across the in-process bonded loopback.
//
// This is the integration test that pins down "the bonded transport
// actually works as a unit." It exercises the scheduler, framing, and
// reassembler together over two virtual links of different latencies, with
// and without loss. Slow on purpose — we use small real-time delays rather
// than fake async so the test reflects the real Timer-driven gap and
// keepalive paths.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:arcane_dispatch/bonded/local_bonded_loopback.dart';
import 'package:arcane_dispatch/core/bonding_mode.dart';

Uint8List _payload(int seed, int len) {
  Uint8List out = Uint8List(len);
  // Deterministic pseudo-random fill so equality checks are meaningful.
  math.Random rng = math.Random(seed);
  for (int i = 0; i < len; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

void main() {
  group('LocalBondedLoopback', () {
    test('stripes a 64 KB stream across two healthy links and reassembles it',
        () async {
      LocalBondedLoopback loop = LocalBondedLoopback(
        links: const <VirtualLinkSpec>[
          // Bandwidth narrow enough that 64 KB saturates credit on each
          // link and forces the scheduler to alternate. Speedify uses a
          // richer BBR-style pacing — v0 is satisfied with "more than one
          // link got traffic".
          VirtualLinkSpec(
            linkId: 'wifi',
            wireId: 1,
            latencyMs: 10,
            bandwidthBps: 200_000.0,
          ),
          VirtualLinkSpec(
            linkId: 'cell',
            wireId: 2,
            latencyMs: 25,
            bandwidthBps: 200_000.0,
          ),
        ],
      )..start();

      try {
        Uint8List stream = _payload(1, 64 * 1024);
        int scheduled = loop.client.send(stream);
        expect(scheduled, stream.length);

        await loop.waitForServerBytes(stream.length,
            timeout: const Duration(seconds: 10));

        Uint8List joined = joinReceived(loop.serverReceived);
        expect(joined.length, stream.length);
        expect(joined, stream);

        // Both links should have carried some bytes — otherwise it's not
        // really bonded.
        Map<String, int> bytesPerLink = loop.client.snapshot().bytesPerLink;
        expect(bytesPerLink['wifi'], greaterThan(0));
        expect(bytesPerLink['cell'], greaterThan(0));
      } finally {
        await loop.dispose();
      }
    });

    test('survives loss on the only available link via NAK retransmits',
        () async {
      // Single lossy link to force every packet through the dropper. The
      // scheduler can't route around the problem, so the reassembler MUST
      // close every hole via NAK retransmits or the stream stalls.
      LocalBondedLoopback loop = LocalBondedLoopback(
        links: const <VirtualLinkSpec>[
          VirtualLinkSpec(
            linkId: 'wifi',
            wireId: 1,
            latencyMs: 10,
            loss: 0.40,
            bandwidthBps: 5_000_000.0,
          ),
        ],
        random: math.Random(0xDEAD),
      )..start(reassemblerGapTimeout: const Duration(milliseconds: 40));

      try {
        Uint8List stream = _payload(2, 4 * 1024);
        loop.client.send(stream);
        await loop.waitForServerBytes(stream.length,
            timeout: const Duration(seconds: 10));

        Uint8List joined = joinReceived(loop.serverReceived);
        expect(joined.length, stream.length);
        expect(joined, stream);

        // The lossy link MUST have dropped at least one packet.
        expect(loop.clientPacketsDropped, greaterThan(0));
        // And the session MUST have retransmitted to recover.
        expect(loop.client.snapshot().retransmissions, greaterThan(0));
      } finally {
        await loop.dispose();
      }
    });

    test('falls through to the only healthy link when the other is 100% lossy',
        () async {
      LocalBondedLoopback loop = LocalBondedLoopback(
        links: const <VirtualLinkSpec>[
          VirtualLinkSpec(linkId: 'wifi', wireId: 1, latencyMs: 10, loss: 1.0),
          VirtualLinkSpec(linkId: 'cell', wireId: 2, latencyMs: 25),
        ],
      )..start(reassemblerGapTimeout: const Duration(milliseconds: 50));

      try {
        Uint8List stream = _payload(3, 4 * 1024);
        loop.client.send(stream);
        await loop.waitForServerBytes(stream.length,
            timeout: const Duration(seconds: 8));

        Uint8List joined = joinReceived(loop.serverReceived);
        expect(joined, stream);
      } finally {
        await loop.dispose();
      }
    });

    test('out-of-order arrival from a slow link still reassembles correctly',
        () async {
      // Big latency gap between the two links forces out-of-order delivery.
      LocalBondedLoopback loop = LocalBondedLoopback(
        links: const <VirtualLinkSpec>[
          VirtualLinkSpec(linkId: 'fast', wireId: 1, latencyMs: 5),
          VirtualLinkSpec(linkId: 'slow', wireId: 2, latencyMs: 80),
        ],
      )..start(reassemblerGapTimeout: const Duration(milliseconds: 200));

      try {
        Uint8List stream = _payload(4, 16 * 1024);
        loop.client.send(stream);
        await loop.waitForServerBytes(stream.length,
            timeout: const Duration(seconds: 8));

        Uint8List joined = joinReceived(loop.serverReceived);
        expect(joined, stream);
      } finally {
        await loop.dispose();
      }
    });

    test(
      'Redundant mode duplicates each chunk to every healthy link and dedups '
      'on the receiver',
      () async {
        // Two clean links, Redundant mode. Each chunk should go out on
        // BOTH links, but the receiver must emit the stream exactly once
        // — the reassembler's duplicate counter MUST be > 0.
        LocalBondedLoopback loop = LocalBondedLoopback(
          links: const <VirtualLinkSpec>[
            VirtualLinkSpec(linkId: 'wifi', wireId: 1, latencyMs: 10),
            VirtualLinkSpec(linkId: 'cell', wireId: 2, latencyMs: 25),
          ],
        )..start(mode: BondingMode.redundant);

        try {
          Uint8List stream = _payload(5, 4 * 1024);
          loop.client.send(stream);
          await loop.waitForServerBytes(stream.length,
              timeout: const Duration(seconds: 8));

          // Wait long enough for the slower link's copy to arrive AFTER
          // the fast link's copy has already advanced _nextSeq. Without
          // this delay we'd snapshot before dedup has a chance to fire.
          await Future<void>.delayed(const Duration(milliseconds: 60));

          // 1. End-to-end stream MUST come through bit-exact even though
          //    every payload was sent twice.
          Uint8List joined = joinReceived(loop.serverReceived);
          expect(joined.length, stream.length);
          expect(joined, stream);

          // 2. Both links MUST have carried bytes (fan-out happened).
          Map<String, int> bytesPerLink = loop.client.snapshot().bytesPerLink;
          expect(bytesPerLink['wifi'], greaterThan(0));
          expect(bytesPerLink['cell'], greaterThan(0));

          // 3. The session MUST report duplicate fan-outs.
          expect(
            loop.client.snapshot().duplicateFanouts,
            greaterThan(0),
            reason: 'Redundant should fan out every chunk to every primary',
          );

          // 4. The receiver's reassembler MUST have seen — and dropped —
          //    duplicate seqs. This is the core Phase 10.6 invariant.
          expect(
            loop.server.reassembler.snapshot().droppedDuplicate,
            greaterThan(0),
            reason: 'Reassembler should dedup duplicate seqs from Redundant',
          );
        } finally {
          await loop.dispose();
        }
      },
    );

    test('setMode at runtime swaps strategies without dropping the stream',
        () async {
      LocalBondedLoopback loop = LocalBondedLoopback(
        links: const <VirtualLinkSpec>[
          VirtualLinkSpec(
            linkId: 'wifi',
            wireId: 1,
            latencyMs: 10,
            bandwidthBps: 200_000.0,
          ),
          VirtualLinkSpec(
            linkId: 'cell',
            wireId: 2,
            latencyMs: 20,
            bandwidthBps: 200_000.0,
          ),
        ],
      )..start();

      try {
        // Speed mode first half.
        Uint8List first = _payload(6, 16 * 1024);
        loop.client.send(first);

        // Wait until at least the first chunk has been transmitted
        // before flipping modes — we want a *mid-stream* change.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        loop.client.setMode(BondingMode.redundant);
        expect(loop.client.strategy.mode, BondingMode.redundant);

        Uint8List second = _payload(7, 16 * 1024);
        loop.client.send(second);

        await loop.waitForServerBytes(first.length + second.length,
            timeout: const Duration(seconds: 10));

        Uint8List joined = joinReceived(loop.serverReceived);
        expect(joined.length, first.length + second.length);
        expect(joined.sublist(0, first.length), first);
        expect(joined.sublist(first.length), second);
      } finally {
        await loop.dispose();
      }
    });
  });
}
