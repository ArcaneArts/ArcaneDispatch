// Per-packet link selector for the bonded transport (Speed mode v0).
//
// Mirror of `lib/bonded/bonded_scheduler.dart`. Keep the algorithm in sync;
// the Dart side has the unit tests that pin behaviour, so any deviation
// here will be caught by the loopback compatibility test once we add a
// cross-language test rig (Phase 8 deliverable).
//
// Algorithm: credit-based picker.
//
//   credit(link) = bandwidthBytesPerSec(link) × rtt(link) − inflightBytes(link)
//
// 1. Filter eligible links by priority bucket (primary → secondary → backup)
//    and health (drop unhealthy/disabled).
// 2. Compute credit for each link in the best bucket; pick the highest.
// 3. If multiple links tie within 1e-6, fall back to weighted RR so the
//    bond converges to the configured weights when credit signals are tied.
// 4. Book the bytes (`inflightBytes += chunkLen`) so subsequent picks see
//    realistic credit. Caller MUST call `completeSend(linkId, bytes)`
//    on ACK / drop so the counter unwinds.

import Foundation

/// Priority bucket mirrors `Link.priority` from the Dart side.
public enum BondedLinkPriority: String, Codable {
    case primary
    case secondary
    case backup
    case never
}

/// Health status mirrors `LinkStatus`.
public enum BondedLinkStatus: String, Codable {
    case healthy
    case degraded
    case unhealthy
    case disabled
    case unknown
}

/// Snapshot of the data the scheduler needs to pick a link. Decoupled
/// from `Link`/`LinkMetric` so the bonded layer doesn't pull in the
/// policy types directly.
public struct BondedLinkState {
    public let linkId: String
    public let wireId: UInt16
    public var priority: BondedLinkPriority
    public var status: BondedLinkStatus
    public var weight: Int
    public var rttMs: Double
    public var bandwidthBps: Double
    public var inflightBytes: Int
    /// Observed packet-loss fraction, 0.0–1.0. Drives Streaming-mode's
    /// duplicate-on-loss decision. 0 means "unknown" — strategies treat
    /// it as "no problem".
    public var lossFraction: Double

    public init(
        linkId: String,
        wireId: UInt16,
        priority: BondedLinkPriority = .primary,
        status: BondedLinkStatus = .unknown,
        weight: Int = 1,
        rttMs: Double = 50.0,
        bandwidthBps: Double = 1_000_000.0,
        inflightBytes: Int = 0,
        lossFraction: Double = 0.0
    ) {
        self.linkId = linkId
        self.wireId = wireId
        self.priority = priority
        self.status = status
        self.weight = weight
        self.rttMs = rttMs
        self.bandwidthBps = bandwidthBps
        self.inflightBytes = inflightBytes
        self.lossFraction = lossFraction
    }
}

/// Result of a single pick. The wireId is what the framer stamps into
/// the outgoing bonded frame.
public struct BondedSchedulingDecision {
    public let linkId: String
    public let wireId: UInt16
    public let credit: Double
    public let wasRoundRobinFallback: Bool
}

/// Speed-mode credit picker. Single-threaded — call from a serial queue.
public final class BondedScheduler {
    /// Insertion-ordered link state. We need stable iteration for the RR
    /// fallback, so `OrderedDictionary` would be nicer but Foundation only
    /// gives us `Dictionary` + a parallel `order` array.
    private var statesMap: [String: BondedLinkState] = [:]
    private var order: [String] = []
    private var rrCursor: Int = 0

    public let minBandwidthBps: Double
    public let minRttMs: Double

    public init(minBandwidthBps: Double = 50_000.0, minRttMs: Double = 1.0) {
        self.minBandwidthBps = minBandwidthBps
        self.minRttMs = minRttMs
    }

    public var linkCount: Int { statesMap.count }

    /// Read-only snapshot for callers that need to iterate. We copy so
    /// the consumer can't mutate scheduler internals.
    public var states: [String: BondedLinkState] { statesMap }

    /// Replace the link set. Preserves existing `inflightBytes` for links
    /// that survive the update; dropped links lose theirs (the caller
    /// should `completeSend` first if accounting matters).
    public func updateLinks(_ incoming: [BondedLinkState]) {
        var next: [String: BondedLinkState] = [:]
        var nextOrder: [String] = []
        for s in incoming {
            var copy = s
            if let prior = statesMap[s.linkId] {
                copy.inflightBytes = prior.inflightBytes
            }
            next[s.linkId] = copy
            nextOrder.append(s.linkId)
        }
        statesMap = next
        order = nextOrder
        if order.isEmpty {
            rrCursor = 0
        } else {
            rrCursor = rrCursor % order.count
        }
    }

    /// Pick a link for an outbound packet of `bytes` bytes. Returns `nil`
    /// when no link is eligible — caller should drop or queue.
    ///
    /// `inflightFraction` scales the BDP cap used in the credit formula.
    /// Speed mode passes 1.0 (default); Streaming mode shrinks it to 0.25
    /// to keep queueing delay minimal. Values outside [0.05, 1.0] are
    /// clamped.
    public func pickLink(bytes: Int, inflightFraction: Double = 1.0) -> BondedSchedulingDecision? {
        if statesMap.isEmpty || bytes <= 0 { return nil }
        var frac = inflightFraction
        if frac < 0.05 { frac = 0.05 }
        if frac > 1.0 { frac = 1.0 }
        let eligible = eligibleByPriority()
        if eligible.isEmpty { return nil }

        var bestCredit: Double = -.infinity
        var winner: String? = nil
        for id in eligible {
            let s = statesMap[id]!
            let c = credit(for: s, fraction: frac)
            if c > bestCredit {
                bestCredit = c
                winner = id
            }
        }

        var wasRR = false
        if winner == nil {
            // Defensive — only happens if every credit was -inf (e.g.
            // someone fed us NaN bandwidth). Pick the first eligible.
            winner = eligible.first
            wasRR = true
            bestCredit = 0
        } else {
            var ties = 0
            for id in eligible {
                let c = credit(for: statesMap[id]!, fraction: frac)
                if abs(bestCredit - c) < 1e-6 { ties += 1 }
            }
            if ties > 1 {
                winner = roundRobinPick(eligible: eligible)
                wasRR = true
            }
        }

        // Book inflight bytes.
        let winId = winner!
        var s = statesMap[winId]!
        s.inflightBytes += bytes
        statesMap[winId] = s
        return BondedSchedulingDecision(
            linkId: winId,
            wireId: s.wireId,
            credit: bestCredit,
            wasRoundRobinFallback: wasRR
        )
    }

    /// Manually book `bytes` of inflight on `linkId`. Strategies that
    /// synthesise their picks (e.g. Redundant duplicating to every link)
    /// call this directly so credit math stays accurate when the user
    /// later switches back to Speed mode.
    public func bookInflight(linkId: String, bytes: Int) {
        guard var s = statesMap[linkId] else { return }
        s.inflightBytes += bytes
        statesMap[linkId] = s
    }

    /// Release `bytes` from the link's inflight counter on ACK / timeout.
    public func completeSend(linkId: String, bytes: Int) {
        guard var s = statesMap[linkId] else { return }
        s.inflightBytes = max(0, s.inflightBytes - bytes)
        statesMap[linkId] = s
    }

    /// Public credit accessor for strategies (e.g. `LocalStrategy`) that
    /// want to evaluate non-default link populations without invoking the
    /// booking side-effect of `pickLink`. Returns 0 when the link is
    /// unknown. Mirrors Dart `BondedScheduler.creditFor`.
    public func creditFor(linkId: String, inflightFraction: Double = 1.0) -> Double {
        guard let s = statesMap[linkId] else { return 0 }
        var frac = inflightFraction
        if frac < 0.05 { frac = 0.05 }
        if frac > 1.0 { frac = 1.0 }
        return credit(for: s, fraction: frac)
    }

    /// Diagnostic alias retained for early tests. New code should call
    /// `creditFor(linkId:inflightFraction:)`.
    public func creditForTest(linkId: String, inflightFraction: Double = 1.0) -> Double {
        creditFor(linkId: linkId, inflightFraction: inflightFraction)
    }

    public func inflightForTest(linkId: String) -> Int {
        statesMap[linkId]?.inflightBytes ?? 0
    }

    // MARK: - internals

    private func credit(for s: BondedLinkState, fraction: Double) -> Double {
        let bw = s.bandwidthBps < minBandwidthBps ? minBandwidthBps : s.bandwidthBps
        let rttMs = s.rttMs < minRttMs ? minRttMs : s.rttMs
        let rttSec = rttMs / 1000.0
        let bdp = bw * rttSec * fraction
        return bdp - Double(s.inflightBytes)
    }

    /// Eligible links inside the best-available priority bucket. We don't
    /// mix buckets — that's the policy engine's job.
    private func eligibleByPriority() -> [String] {
        if statesMap.isEmpty { return [] }
        for bucket: BondedLinkPriority in [.primary, .secondary, .backup] {
            var ids: [String] = []
            for id in order {
                let s = statesMap[id]!
                if s.priority != bucket { continue }
                if s.status == .unhealthy || s.status == .disabled { continue }
                ids.append(id)
            }
            if !ids.isEmpty { return ids }
        }
        return []
    }

    private func roundRobinPick(eligible: [String]) -> String {
        if eligible.count == 1 {
            rrCursor = (rrCursor + 1) % max(order.count, 1)
            return eligible.first!
        }
        let start = rrCursor
        var picked = eligible.first!
        for i in 0..<order.count {
            let idx = (start + i) % order.count
            let candidate = order[idx]
            if eligible.contains(candidate) {
                picked = candidate
                rrCursor = (idx + 1) % order.count
                return picked
            }
        }
        return picked
    }
}
