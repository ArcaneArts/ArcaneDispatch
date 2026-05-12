// Swift mirror of `lib/protocol/protocol_ladder.dart`.
//
// Used by the Network Extension to negotiate the best transport for each
// link (UDP -> TCP -> TLS-on-443). Tries probes in priority order with
// per-step timeouts and returns the first that succeeds.

import Foundation

public enum LinkProtocol: String, Codable, Sendable {
    case udp
    case tcp
    case tlsHttps = "tls_https"
}

public struct ProtocolStep: Sendable {
    public let proto: LinkProtocol
    public let port: Int
    public let timeoutMs: Int

    public init(proto: LinkProtocol, port: Int, timeoutMs: Int = 1500) {
        precondition((1...65535).contains(port), "port out of range")
        precondition(timeoutMs > 0, "timeoutMs must be positive")
        self.proto = proto
        self.port = port
        self.timeoutMs = timeoutMs
    }
}

public struct NegotiatedProtocol: Sendable, Equatable {
    public let proto: LinkProtocol
    public let port: Int
    public let attempts: Int

    public init(proto: LinkProtocol, port: Int, attempts: Int) {
        self.proto = proto
        self.port = port
        self.attempts = attempts
    }
}

public struct ProtocolLadderError: Error, CustomStringConvertible {
    public let lastError: Error?
    public init(lastError: Error?) { self.lastError = lastError }
    public var description: String {
        let inner = lastError.map { ": \($0)" } ?? ""
        return "ProtocolLadderError: no transport succeeded\(inner)"
    }
}

public actor ProtocolLadder {
    public typealias Prober = @Sendable (LinkProtocol, Int, TimeInterval) async throws -> Void

    private let prober: Prober
    private let ladder: [ProtocolStep]

    public init(
        ladder: [ProtocolStep] = ProtocolLadder.defaultLadder(),
        prober: @escaping Prober
    ) {
        precondition(!ladder.isEmpty, "ladder must not be empty")
        self.ladder = ladder
        self.prober = prober
    }

    public static func defaultLadder() -> [ProtocolStep] {
        return [
            ProtocolStep(proto: .udp, port: 4430, timeoutMs: 800),
            ProtocolStep(proto: .tcp, port: 4430, timeoutMs: 1500),
            ProtocolStep(proto: .tlsHttps, port: 443, timeoutMs: 2500),
        ]
    }

    public var steps: [ProtocolStep] { ladder }

    public func negotiate() async throws -> NegotiatedProtocol {
        var lastError: Error?
        var attempts = 0
        for step in ladder {
            attempts += 1
            do {
                try await prober(step.proto, step.port, Double(step.timeoutMs) / 1000.0)
                return NegotiatedProtocol(proto: step.proto, port: step.port, attempts: attempts)
            } catch {
                lastError = error
                continue
            }
        }
        throw ProtocolLadderError(lastError: lastError)
    }
}
