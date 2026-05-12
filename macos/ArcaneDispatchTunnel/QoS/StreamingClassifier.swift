// Swift mirror of lib/qos/streaming_classifier.dart.
//
// Phase 12 of plans/2026-05-11-speedify-clone-v1.md.
//
// Pure stateless classifier. Lives in the Network Extension so it can decide
// the realtime flag at the moment a flow is admitted, before any chunks ship.

import Foundation

enum FlowTransport: UInt8 {
    case tcp = 0
    case udp = 1
}

enum StreamingVerdict: UInt8 {
    case realtime = 0
    case normal = 1
    case unknown = 2
}

struct StreamingFlowProbe {
    let destPort: UInt16
    let transport: FlowTransport
    var destIpV4: [UInt8]? = nil
    var destIpV6: [UInt8]? = nil
    var sni: String? = nil
    var processName: String? = nil
}

struct CidrRule {
    let bytes: [UInt8]
    let prefixBits: Int

    init(bytes: [UInt8], prefixBits: Int) {
        self.bytes = bytes
        self.prefixBits = prefixBits
    }

    static func parse(_ text: String) -> CidrRule? {
        guard let slash = text.firstIndex(of: "/") else { return nil }
        let addr = String(text[..<slash])
        let prefixStr = String(text[text.index(after: slash)...])
        guard let prefix = Int(prefixStr) else { return nil }
        if addr.contains(":") {
            guard let v6 = parseIPv6(addr) else { return nil }
            return CidrRule(bytes: v6, prefixBits: prefix)
        }
        guard let v4 = parseIPv4(addr) else { return nil }
        return CidrRule(bytes: v4, prefixBits: prefix)
    }

    func matches(_ ip: [UInt8]) -> Bool {
        guard ip.count == bytes.count else { return false }
        let fullBytes = prefixBits / 8
        for i in 0..<fullBytes {
            if ip[i] != bytes[i] { return false }
        }
        let remainder = prefixBits % 8
        if remainder == 0 { return true }
        let mask: UInt8 = UInt8((0xFF << (8 - remainder)) & 0xFF)
        return (ip[fullBytes] & mask) == (bytes[fullBytes] & mask)
    }

    private static func parseIPv4(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(4)
        for p in parts {
            guard let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    private static func parseIPv6(_ text: String) -> [UInt8]? {
        var segments = [UInt16]()
        let chunks = text.components(separatedBy: "::")
        if chunks.count > 2 { return nil }
        let leftParts: [String] = chunks[0].isEmpty ? [] : chunks[0].split(separator: ":").map(String.init)
        let rightParts: [String] = chunks.count == 2
            ? (chunks[1].isEmpty ? [] : chunks[1].split(separator: ":").map(String.init))
            : []
        let missing = 8 - leftParts.count - rightParts.count
        if missing < 0 { return nil }
        for h in leftParts {
            guard let v = UInt16(h, radix: 16) else { return nil }
            segments.append(v)
        }
        for _ in 0..<missing { segments.append(0) }
        for h in rightParts {
            guard let v = UInt16(h, radix: 16) else { return nil }
            segments.append(v)
        }
        guard segments.count == 8 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(16)
        for seg in segments {
            out.append(UInt8((seg >> 8) & 0xFF))
            out.append(UInt8(seg & 0xFF))
        }
        return out
    }
}

struct StreamingRules {
    var rtPortsUdp: Set<UInt16>
    var rtPortsTcp: Set<UInt16>
    var cidrs: [CidrRule]
    var sniSubstrings: [String]
    var processAllowList: [String]

    static let `default`: StreamingRules = {
        let udp: Set<UInt16> = [
            3478, 3479, 5349, 5350,
            19302, 19303, 19305, 19306, 19307, 19308, 19309,
            5060, 5061,
            8801, 8802, 8803, 8804,
            50000, 50001, 50002, 50003, 50004, 50005,
        ]
        let tcp: Set<UInt16> = [
            5060, 5061,
            554, 1935,
            50080, 50081,
        ]
        let cidrs: [CidrRule] = [
            "50.239.0.0/16",
            "64.211.144.0/24",
            "74.125.250.0/24",
            "162.159.128.0/19",
            "52.112.0.0/14",
        ].compactMap(CidrRule.parse)
        let sni = [
            "zoom.us", "zoomgov.com",
            "meet.google",
            "teams.microsoft", "teams.live",
            "discord.gg", "discord.media",
            "webex.com", "whereby.com", "jitsi.",
        ]
        return StreamingRules(
            rtPortsUdp: udp,
            rtPortsTcp: tcp,
            cidrs: cidrs,
            sniSubstrings: sni,
            processAllowList: []
        )
    }()
}

final class StreamingClassifier {
    private(set) var rules: StreamingRules

    init(rules: StreamingRules = .default) {
        self.rules = rules
    }

    func setRules(_ next: StreamingRules) {
        rules = next
    }

    func classify(_ probe: StreamingFlowProbe) -> StreamingVerdict {
        if let proc = probe.processName?.lowercased(),
           rules.processAllowList.contains(where: { proc.contains($0.lowercased()) }) {
            return .realtime
        }
        if let sni = probe.sni?.lowercased() {
            for needle in rules.sniSubstrings where sni.contains(needle.lowercased()) {
                return .realtime
            }
        }
        let ports = probe.transport == .udp ? rules.rtPortsUdp : rules.rtPortsTcp
        if ports.contains(probe.destPort) {
            return .realtime
        }
        if probe.transport == .udp, probe.destPort >= 16384, probe.destPort <= 32767 {
            return .realtime
        }
        if let ip = probe.destIpV4 ?? probe.destIpV6 {
            for cidr in rules.cidrs where cidr.matches(ip) {
                return .realtime
            }
        }
        if probe.destIpV4 == nil, probe.destIpV6 == nil, probe.sni == nil {
            return .unknown
        }
        return .normal
    }
}
