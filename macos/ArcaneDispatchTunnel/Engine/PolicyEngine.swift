// PolicyEngine.swift
//
// Swift port of the Dart `PolicyEngine` (`lib/policy/policy_engine.dart`).
// Same eligibility cascade, same weight normalization, same priority-group
// fallback semantics. Kept structurally identical so we can fuzz both sides
// against the same vectors and catch drift between Dart and Swift early.
//
// This file deliberately depends only on Foundation + the local
// `ExtensionPolicy`/`PolicyLink` types. No NetworkExtension imports — the
// engine is pure, so the unit tests in `macos/ArcaneDispatchTunnelTests/`
// can exercise it without a tunnel.

import Foundation

/// Priority bucket. Mirrors `LinkPriority` on the Dart side.
enum LinkPriority: String, Codable {
    case primary
    case secondary
    case backup
    case never

    /// 0 = primary, 1 = secondary, 2 = backup, 3 = never. Used for the
    /// `groupRank` field of `EligibleLink`.
    var rank: Int {
        switch self {
        case .primary: return 0
        case .secondary: return 1
        case .backup: return 2
        case .never: return 3
        }
    }

    init(wire: String?) {
        switch (wire ?? "").lowercased() {
        case "primary": self = .primary
        case "secondary": self = .secondary
        case "backup": self = .backup
        case "never": self = .never
        default: self = .primary
        }
    }
}

/// Live snapshot for one link. Populated from probe data delivered by the
/// container app or, eventually, by the bonded transport's own per-link
/// keepalives. Mirrors `LinkMetric` on the Dart side, fields only.
struct LinkMetricSample: Codable {
    /// RTT in milliseconds, nil when unknown.
    let rttMs: Double?
    /// Loss as a fraction in `[0.0, 1.0]`, nil when unknown.
    let loss: Double?
}

/// Why a link was excluded from the active eligible set.
enum IneligibilityReason: String {
    case never
    case noSource
    case highLoss
    case highRtt
    case dataCapExhausted
    case groupSuperseded
}

/// One link the engine has decided is currently eligible to carry flows.
struct EligibleLink {
    let link: PolicyLink
    /// Always >= 1, integer for use with a classic weighted-RR token wheel.
    let weight: Int
    /// 0 = primary, 1 = secondary, 2 = backup.
    let groupRank: Int
    /// Bucket the link belongs to. Equal to its raw priority for the active
    /// group's members; informative for logs ("primary degraded").
    let sourcePriority: LinkPriority
}

struct IneligibleLink {
    let link: PolicyLink
    let reason: IneligibilityReason
}

/// Full output of one `PolicyEngine.evaluate` pass.
struct PolicyDecision {
    let eligible: [EligibleLink]
    let ineligible: [IneligibleLink]
    /// Group the engine settled on, or `nil` when nothing is eligible. The
    /// `PacketPump` interprets `nil + killSwitch == true` as "drop every
    /// outbound packet" — the kill-switch contract from Phase 4 also covers
    /// the system-wide tunnel.
    let activeGroup: LinkPriority?

    var hasEligible: Bool { !eligible.isEmpty }
}

/// Health gates and weight-normalization bounds. Mirrors the Dart defaults so
/// the engine on both sides produces matching decisions for the same input.
struct PolicyEngineThresholds {
    let maxLoss: Double
    let maxRttMs: Double
    let minNormalizedShare: Double
    let maxNormalizedShare: Double

    init(
        maxLoss: Double = 0.30,
        maxRttMs: Double = 1500.0,
        minNormalizedShare: Double = 0.05,
        maxNormalizedShare: Double = 0.95
    ) {
        self.maxLoss = maxLoss
        self.maxRttMs = maxRttMs
        self.minNormalizedShare = minNormalizedShare
        self.maxNormalizedShare = maxNormalizedShare
    }
}

/// Pure decision function. Stateless on purpose so the same inputs always
/// produce the same output — the call site can throw the engine on any
/// queue without worrying about contention.
struct PolicyEngine {
    let thresholds: PolicyEngineThresholds

    init(thresholds: PolicyEngineThresholds = PolicyEngineThresholds()) {
        self.thresholds = thresholds
    }

    /// Evaluate `policy` against the current `metrics` snapshot.
    ///
    /// - parameter dataUsedOverride: live data-meter counters keyed by linkId.
    ///   Consulted ahead of `link.dataUsedBytes` so the bonded scheduler can
    ///   feed real-time numbers without writing them back to the policy JSON
    ///   on every byte.
    func evaluate(
        policy: ExtensionPolicy,
        metrics: [String: LinkMetricSample] = [:],
        dataUsedOverride: [String: Int] = [:]
    ) -> PolicyDecision {
        var ineligible: [IneligibleLink] = []
        var eligibleByGroup: [LinkPriority: [PolicyLink]] = [
            .primary: [],
            .secondary: [],
            .backup: [],
        ]

        for link in policy.links {
            let priority = LinkPriority(wire: link.priority)

            // Never: always rejected, even with otherwise perfect metrics.
            if priority == .never {
                ineligible.append(IneligibleLink(link: link, reason: .never))
                continue
            }

            // No source binding → can't actually send packets through it.
            let hasInterface = (link.interfaceName?.isEmpty == false)
            let hasSource = (link.sourceAddress?.isEmpty == false)
            if !hasInterface && !hasSource {
                ineligible.append(IneligibleLink(link: link, reason: .noSource))
                continue
            }

            // Health gates. Missing metrics = treat as healthy (haven't probed
            // yet); only explicit threshold breaches drop a link.
            if let metric = metrics[link.id] {
                if let loss = metric.loss, loss > thresholds.maxLoss {
                    ineligible.append(IneligibleLink(link: link, reason: .highLoss))
                    continue
                }
                if let rtt = metric.rttMs, rtt > thresholds.maxRttMs {
                    ineligible.append(IneligibleLink(link: link, reason: .highRtt))
                    continue
                }
            }

            // Data cap. Override beats persisted counter so the live meter wins.
            let dataUsed = dataUsedOverride[link.id] ?? (link.dataUsedBytes ?? 0)
            if let cap = link.dataCapBytes, cap > 0, dataUsed >= cap {
                ineligible.append(IneligibleLink(link: link, reason: .dataCapExhausted))
                continue
            }

            eligibleByGroup[priority, default: []].append(link)
        }

        // Walk priority groups in order — first non-empty group wins.
        var activeGroup: LinkPriority? = nil
        var activeMembers: [PolicyLink] = []
        for candidate in [LinkPriority.primary, .secondary, .backup] {
            let members = eligibleByGroup[candidate] ?? []
            if !members.isEmpty {
                activeGroup = candidate
                activeMembers = members
                break
            }
        }

        // Demote eligible-but-superseded groups to ineligible so the UI can
        // show "primary fine but secondary not in use" semantics.
        if let active = activeGroup {
            for (group, members) in eligibleByGroup where group != active {
                for link in members {
                    ineligible.append(IneligibleLink(link: link, reason: .groupSuperseded))
                }
            }
        }

        guard let active = activeGroup else {
            return PolicyDecision(eligible: [], ineligible: ineligible, activeGroup: nil)
        }

        let weights = computeWeights(activeMembers)
        let eligible: [EligibleLink] = zip(activeMembers, weights).map { (link, weight) in
            EligibleLink(
                link: link,
                weight: weight,
                groupRank: active.rank,
                sourcePriority: LinkPriority(wire: link.priority)
            )
        }

        return PolicyDecision(
            eligible: eligible,
            ineligible: ineligible,
            activeGroup: active
        )
    }

    /// Map per-link speed caps onto integer weights summing to roughly 100.
    /// Mirrors the Dart algorithm step-for-step:
    /// * No caps anywhere → use `link.weight` (defaults to 1) as the
    ///   classic weighted-RR weight.
    /// * Any cap set → treat uncapped members as having a sentinel cap
    ///   (10× the largest configured), proportion-share, clamp shares to
    ///   `[minNormalizedShare, maxNormalizedShare]`, renormalize, and scale
    ///   to integers (minimum 1).
    private func computeWeights(_ members: [PolicyLink]) -> [Int] {
        if members.isEmpty { return [] }
        let anyCapped = members.contains { $0.speedCapBps != nil }
        if !anyCapped {
            return members.map { max(1, $0.weight ?? 1) }
        }
        let maxConfiguredCap = members.compactMap { $0.speedCapBps }.max() ?? 0
        let uncappedSentinel: Int = maxConfiguredCap > 0
            ? maxConfiguredCap * 10
            : 1_000_000_000
        let raw: [Double] = members.map { Double($0.speedCapBps ?? uncappedSentinel) }
        let sum = raw.reduce(0.0, +)
        if sum <= 0 { return members.map { _ in 1 } }
        let shares: [Double] = raw.map { value in
            min(max(value / sum, thresholds.minNormalizedShare), thresholds.maxNormalizedShare)
        }
        let normalize = shares.reduce(0.0, +)
        if normalize <= 0 { return members.map { _ in 1 } }
        return shares.map { share in
            max(1, Int((share / normalize * 100.0).rounded()))
        }
    }
}
