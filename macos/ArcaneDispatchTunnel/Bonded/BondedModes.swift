// Per-mode scheduling strategies for the bonded transport.
//
// Mirror of `lib/bonded/bonded_modes.dart`. The Dart side has the unit
// tests that pin behaviour; this file follows them closely so the
// container app and the system extension agree on per-mode semantics
// (Speed = single-link pick, Redundant = fan-out, Streaming = small
// inflight + duplicate-on-loss, Local = peer-routed placeholder).
//
// Wiring inside the extension: `PacketPump` picks a strategy based on
// the active `Policy.bondingMode`, then asks
// `strategy.planChunk(bytes:scheduler:)` for the list of (linkId,
// wireId) sends to make. `BondedClient` then encodes one bonded frame
// per send entry, all sharing the same outbound seq so the receiver's
// reassembler dedups duplicates natively (the same property the Dart
// loopback test pins down).

import Foundation

/// Mirror of the Dart `BondingMode` enum. Wire format is the lowercase
/// case name, matching the JSON value in policy.json.
public enum BondedBondingMode: String, Codable {
    case speed
    case redundant
    case streaming
    case local
}

/// A single (linkId, wireId, credit) tuple. Same shape as
/// `BondedSchedulingDecision` — re-aliased so call sites read naturally.
public typealias BondedSendPlan = BondedSchedulingDecision

/// Per-chunk plan emitted by `BondedModeStrategy.planChunk`. The pump /
/// client iterates `sends` and encodes one bonded frame per entry, all
/// sharing the same outbound seq so the receiver naturally dedupes.
public struct BondedChunkPlan {
    /// Ordered list of link picks for this chunk. Empty means "drop or
    /// queue, no eligible links right now".
    public let sends: [BondedSendPlan]

    /// True iff the strategy already booked inflight for each send via
    /// `BondedScheduler.bookInflight`. The pump/client checks this to
    /// avoid double-booking when it builds the encoded frames.
    public let inflightBooked: Bool

    public init(sends: [BondedSendPlan], inflightBooked: Bool = true) {
        self.sends = sends
        self.inflightBooked = inflightBooked
    }

    public static var empty: BondedChunkPlan {
        return BondedChunkPlan(sends: [], inflightBooked: true)
    }

    public var isEmpty: Bool { sends.isEmpty }
    public var fanout: Int { sends.count }
}

/// Strategy contract. Stateless w.r.t. the scheduler; reads scheduler
/// state via the passed-in instance but doesn't own it.
public protocol BondedModeStrategy: AnyObject {
    var mode: BondedBondingMode { get }
    func planChunk(bytes: Int, scheduler: BondedScheduler) -> BondedChunkPlan
}

/// Factory: pick a strategy for `mode`. Centralised so the pump and any
/// future test rigs agree on which class implements each mode.
public enum BondedModes {
    public static func strategy(for mode: BondedBondingMode) -> BondedModeStrategy {
        switch mode {
        case .speed:
            return SpeedStrategy()
        case .redundant:
            return RedundantStrategy()
        case .streaming:
            return StreamingStrategy()
        case .local:
            return LocalStrategy()
        }
    }

    /// Bound the inflight-fraction the way the Dart `clampFractionForTest`
    /// helper does. Exposed so the Swift unit test (when we add one)
    /// can pin the same bounds as Dart.
    public static func clampFraction(_ v: Double) -> Double {
        return max(0.05, min(1.0, v))
    }
}

/// Default Speed mode: delegate straight to the credit scheduler.
public final class SpeedStrategy: BondedModeStrategy {
    public var mode: BondedBondingMode { .speed }

    public init() {}

    public func planChunk(bytes: Int, scheduler: BondedScheduler) -> BondedChunkPlan {
        guard let d = scheduler.pickLink(bytes: bytes) else { return .empty }
        return BondedChunkPlan(sends: [d])
    }
}

/// Redundant mode: ship the chunk on every healthy primary link. If no
/// primary links exist, fan out to the best non-never bucket instead so
/// the user still has redundancy on a degraded network.
public final class RedundantStrategy: BondedModeStrategy {
    public var mode: BondedBondingMode { .redundant }

    public init() {}

    public func planChunk(bytes: Int, scheduler: BondedScheduler) -> BondedChunkPlan {
        let primaries = eligibleLinks(scheduler: scheduler)
        if primaries.isEmpty { return .empty }
        var sends: [BondedSendPlan] = []
        for s in primaries {
            // We book inflight ourselves so the credit signals stay
            // meaningful for a future Speed-mode switch mid-flow.
            scheduler.bookInflight(linkId: s.linkId, bytes: bytes)
            sends.append(BondedSendPlan(
                linkId: s.linkId,
                wireId: s.wireId,
                credit: 0,
                wasRoundRobinFallback: false
            ))
        }
        return BondedChunkPlan(sends: sends, inflightBooked: true)
    }

    /// Healthy links in the best bucket that has any. Mirrors the Dart
    /// `RedundantStrategy._eligibleLinks` algorithm 1:1.
    private func eligibleLinks(scheduler: BondedScheduler) -> [BondedLinkState] {
        let states = scheduler.states
        for bucket: BondedLinkPriority in [.primary, .secondary, .backup] {
            var ids: [BondedLinkState] = []
            for s in states.values {
                if s.priority != bucket { continue }
                if s.status == .unhealthy || s.status == .disabled { continue }
                ids.append(s)
            }
            if !ids.isEmpty { return ids }
        }
        return []
    }
}

/// Streaming mode: like Speed, but with a tight inflight cap (0.25× BDP
/// instead of 1× BDP) so jitter stays low. When *any* eligible link is
/// observing > 1 % loss the chunk falls back to Redundant fan-out to
/// that link plus the next-best so RT flows survive bursty drops.
public final class StreamingStrategy: BondedModeStrategy {
    public var mode: BondedBondingMode { .streaming }

    /// Loss fraction threshold above which we fall back to Redundant
    /// for the affected chunk. Default 0.01 = 1 %.
    public let lossDuplicateThreshold: Double

    /// Inflight cap multiplier. Speed treats BDP as the cap; Streaming
    /// shrinks it to keep queueing delay minimal. Default 0.25.
    public let inflightFraction: Double

    public init(
        lossDuplicateThreshold: Double = 0.01,
        inflightFraction: Double = 0.25
    ) {
        self.lossDuplicateThreshold = lossDuplicateThreshold
        self.inflightFraction = inflightFraction
    }

    public func planChunk(bytes: Int, scheduler: BondedScheduler) -> BondedChunkPlan {
        guard let primary = scheduler.pickLink(
            bytes: bytes,
            inflightFraction: inflightFraction
        ) else {
            return .empty
        }
        let primaryState = scheduler.states[primary.linkId]
        let observedLoss = primaryState?.lossFraction ?? 0.0
        if observedLoss < lossDuplicateThreshold {
            return BondedChunkPlan(sends: [primary])
        }
        // Loss is high enough that we duplicate to a backup link if
        // one is available.
        guard let secondary = bestSecondary(
            scheduler: scheduler,
            excludeLinkId: primary.linkId
        ) else {
            return BondedChunkPlan(sends: [primary])
        }
        scheduler.bookInflight(linkId: secondary.linkId, bytes: bytes)
        return BondedChunkPlan(
            sends: [
                primary,
                BondedSendPlan(
                    linkId: secondary.linkId,
                    wireId: secondary.wireId,
                    credit: 0,
                    wasRoundRobinFallback: false
                ),
            ],
            inflightBooked: true
        )
    }

    private func bestSecondary(
        scheduler: BondedScheduler,
        excludeLinkId: String
    ) -> BondedLinkState? {
        var winner: BondedLinkState? = nil
        var bestRtt: Double = .infinity
        for s in scheduler.states.values {
            if s.linkId == excludeLinkId { continue }
            if s.status == .unhealthy || s.status == .disabled { continue }
            if s.priority == .never { continue }
            if s.rttMs < bestRtt {
                winner = s
                bestRtt = s.rttMs
            }
        }
        return winner
    }
}

/// Local-mode strategy used when bonding without a remote relay.
///
/// Routing preference: paired peers come first. When any paired link
/// (id prefix `paired:`) is healthy *and* has positive credit, Local
/// mode prefers it over local interfaces — this is the spec for
/// "Local mode active" with a Pair & Share peer attached. If no paired
/// link is available, falls through to a normal single-link pick. This
/// matches the Dart `LocalStrategy._pickPaired` behaviour exactly.
public final class LocalStrategy: BondedModeStrategy {
    public var mode: BondedBondingMode { .local }

    public init() {}

    public func planChunk(bytes: Int, scheduler: BondedScheduler) -> BondedChunkPlan {
        // First pass: try to pick a paired peer directly.
        if let paired = pickPaired(scheduler: scheduler, bytes: bytes) {
            return BondedChunkPlan(sends: [paired])
        }
        // No paired peer eligible → fall back to whatever the scheduler picks.
        guard let d = scheduler.pickLink(bytes: bytes) else { return .empty }
        return BondedChunkPlan(sends: [d])
    }

    /// Returns the best paired link if one is healthy with credit, else
    /// nil. We filter on the `paired:` linkId convention used by the
    /// Pair & Share registry.
    private func pickPaired(scheduler: BondedScheduler, bytes: Int) -> BondedSendPlan? {
        var winner: BondedLinkState? = nil
        var bestScore: Double = -1
        var bestCredit: Double = 0
        for (linkId, s) in scheduler.states {
            if !linkId.hasPrefix("paired:") { continue }
            if s.status == .unhealthy || s.status == .disabled { continue }
            if s.priority == .never { continue }
            let credit = scheduler.creditFor(linkId: linkId)
            if credit <= 0 { continue }
            let score = credit / (1.0 + s.rttMs)
            if score > bestScore {
                bestScore = score
                bestCredit = credit
                winner = s
            }
        }
        guard let pick = winner else { return nil }
        scheduler.bookInflight(linkId: pick.linkId, bytes: bytes)
        return BondedSendPlan(
            linkId: pick.linkId,
            wireId: pick.wireId,
            credit: bestCredit,
            wasRoundRobinFallback: false
        )
    }
}
