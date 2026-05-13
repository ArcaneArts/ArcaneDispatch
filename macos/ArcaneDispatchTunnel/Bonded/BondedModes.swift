import Foundation

public enum BondedBondingMode: String, Codable {
    case speed
    case redundant
}

public typealias BondedSendPlan = BondedSchedulingDecision

public struct BondedChunkPlan {
    public let sends: [BondedSendPlan]
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

public protocol BondedModeStrategy: AnyObject {
    var mode: BondedBondingMode { get }
    func planChunk(bytes: Int, scheduler: BondedScheduler) -> BondedChunkPlan
}

public enum BondedModes {
    public static func strategy(for mode: BondedBondingMode) -> BondedModeStrategy {
        switch mode {
        case .speed:
            return SpeedStrategy()
        case .redundant:
            return RedundantStrategy()
        }
    }

    public static func clampFraction(_ value: Double) -> Double {
        return max(0.05, min(1.0, value))
    }
}

public final class SpeedStrategy: BondedModeStrategy {
    public var mode: BondedBondingMode { .speed }

    public init() {}

    public func planChunk(bytes: Int, scheduler: BondedScheduler) -> BondedChunkPlan {
        guard let decision = scheduler.pickLink(bytes: bytes) else {
            return .empty
        }
        return BondedChunkPlan(sends: [decision])
    }
}

public final class RedundantStrategy: BondedModeStrategy {
    public var mode: BondedBondingMode { .redundant }

    public init() {}

    public func planChunk(bytes: Int, scheduler: BondedScheduler) -> BondedChunkPlan {
        let links = eligibleLinks(scheduler: scheduler)
        if links.isEmpty {
            return .empty
        }
        var sends: [BondedSendPlan] = []
        for state in links {
            scheduler.bookInflight(linkId: state.linkId, bytes: bytes)
            sends.append(BondedSendPlan(
                linkId: state.linkId,
                wireId: state.wireId,
                credit: 0,
                wasRoundRobinFallback: false
            ))
        }
        return BondedChunkPlan(sends: sends, inflightBooked: true)
    }

    private func eligibleLinks(scheduler: BondedScheduler) -> [BondedLinkState] {
        let states = scheduler.states
        for bucket: BondedLinkPriority in [.primary, .secondary, .backup] {
            var links: [BondedLinkState] = []
            for state in states.values {
                if state.priority != bucket { continue }
                if state.status == .unhealthy || state.status == .disabled { continue }
                links.append(state)
            }
            if !links.isEmpty {
                return links
            }
        }
        return []
    }
}
