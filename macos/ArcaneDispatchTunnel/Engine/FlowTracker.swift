// FlowTracker.swift
//
// Lightweight per-flow bookkeeping for the macOS Network Extension.
//
// What it does:
//   1. Parses just enough of each IP packet (v4 + v6) to extract the 5-tuple
//      that identifies the flow it belongs to.
//   2. Keeps a hash table of live flows keyed by that 5-tuple, each tagged
//      with the linkId the `PolicyEngine` decided to send/receive it on.
//
// Deliberately ignores anything more than the absolute minimum we need:
// no IPv6 extension headers, no IP fragmentation, no TCP option parsing.
// The reassembly/encryption/etc. all happen later (Phase 7+).

import Foundation

/// Address family the flow lives in. Stored alongside the addresses so the
/// stringly-typed `localAddress`/`remoteAddress` doesn't have to be parsed
/// again on the read side.
enum FlowFamily: UInt8 {
    case ipv4 = 4
    case ipv6 = 6
}

/// Which side of the tunnel a packet was crossing when we observed it.
enum FlowDirection {
    /// Read from `packetFlow.readPackets` — local app → internet.
    case outbound
    /// Headed to `packetFlow.writePackets` — internet → local app.
    case inbound
}

/// Canonical key for a flow. "Local" is always the kernel side (the app's
/// socket), "remote" is always the public side. Direction is resolved when
/// the packet is observed; the key is direction-independent.
struct FlowKey: Hashable {
    let localAddress: String
    let localPort: UInt16
    let remoteAddress: String
    let remotePort: UInt16
    /// IPPROTO_TCP = 6, IPPROTO_UDP = 17. Other protocols (ICMP, GRE, etc.)
    /// can still flow through the tunnel but won't get pinned to a link —
    /// the engine treats them as best-effort.
    let networkProtocol: UInt8
    let family: FlowFamily
}

/// One observed flow's running state. `let`-heavy on purpose; mutators
/// return new copies via small helpers so the public surface stays
/// immutable to the engine code that reads it.
struct Flow {
    /// Monotonically allocated ID. Stable for the lifetime of the flow so
    /// the Dart UI can address it without re-keying on the 5-tuple.
    let id: UInt64
    let key: FlowKey
    /// Stable, pinned link ID for the flow's whole lifetime in Phase 6.
    /// Phase 7 (bonded mode) will swap this for a per-packet decision.
    var linkId: String
    /// Bytes the local app sent out through the tunnel.
    var bytesOut: UInt64
    /// Bytes the network sent back into the tunnel for the local app.
    var bytesIn: UInt64
    /// Wall-clock seconds since Unix epoch when the flow was first seen.
    let createdAt: TimeInterval
    /// Wall-clock seconds since Unix epoch of the last byte we observed in
    /// either direction. Drives idle-sweep based GC.
    var lastSeen: TimeInterval
}

/// Tracker + minimal parser. Single-threaded by contract — `PacketPump`
/// pins everything to `tunnel-io` so no locking is needed inside.
final class FlowTracker {
    typealias LinkAssigner = (FlowKey) -> String?

    private var flows: [FlowKey: Flow] = [:]
    private var nextId: UInt64 = 1
    init() {}

    /// Observe one packet. If the packet's 5-tuple is parseable, we either
    /// create a new flow (calling `linkAssigner` to pick the outbound link)
    /// or update the existing flow's byte counters.
    ///
    /// Returns the resolved flow (or nil for unparseable packets). The
    /// caller uses the returned `linkId` to actually forward the packet.
    @discardableResult
    func observe(
        packet: Data,
        direction: FlowDirection,
        linkAssigner: LinkAssigner
    ) -> Flow? {
        guard let (key, payloadLen) = parseFlowKey(packet: packet, direction: direction) else {
            return nil
        }

        let now = Date().timeIntervalSince1970

        if var flow = flows[key] {
            if direction == .outbound {
                flow.bytesOut &+= UInt64(payloadLen)
            } else {
                flow.bytesIn &+= UInt64(payloadLen)
            }
            flow.lastSeen = now
            flows[key] = flow
            return flow
        }

        let linkId = linkAssigner(key) ?? ""
        let flow = Flow(
            id: nextId,
            key: key,
            linkId: linkId,
            bytesOut: direction == .outbound ? UInt64(payloadLen) : 0,
            bytesIn: direction == .inbound ? UInt64(payloadLen) : 0,
            createdAt: now,
            lastSeen: now
        )
        nextId &+= 1
        flows[key] = flow
        return flow
    }

    /// Drop flows that haven't seen traffic in `idleTimeout`.
    func sweep(idleTimeout: TimeInterval) {
        let now = Date().timeIntervalSince1970
        let stale = flows.values.filter { now - $0.lastSeen > idleTimeout }
        for flow in stale {
            flows.removeValue(forKey: flow.key)
        }
    }

    // MARK: - Internals -------------------------------------------------------

    /// Parse the absolute minimum needed for a 5-tuple. Returns nil on any
    /// packet we don't recognize. Side-effect free.
    ///
    /// - Returns: `(FlowKey, payloadByteCount)`. The payload count is what we
    ///   credit toward the flow's byte counter — it excludes IP+L4 headers
    ///   so the UI shows app-visible throughput, not wire bytes.
    private func parseFlowKey(packet: Data, direction: FlowDirection) -> (FlowKey, Int)? {
        guard packet.count >= 20 else { return nil }
        let versionNibble = packet[0] >> 4
        switch versionNibble {
        case 4:
            return parseIPv4(packet: packet, direction: direction)
        case 6:
            return parseIPv6(packet: packet, direction: direction)
        default:
            return nil
        }
    }

    private func parseIPv4(packet: Data, direction: FlowDirection) -> (FlowKey, Int)? {
        let ihl = Int(packet[0] & 0x0F) * 4
        guard ihl >= 20, packet.count >= ihl else { return nil }
        let proto = packet[9]
        // Only pin TCP/UDP. Other protocols still flow but stay unkeyed.
        guard proto == 6 || proto == 17 else { return nil }

        let totalLen = (Int(packet[2]) << 8) | Int(packet[3])
        let srcIP = "\(packet[12]).\(packet[13]).\(packet[14]).\(packet[15])"
        let dstIP = "\(packet[16]).\(packet[17]).\(packet[18]).\(packet[19])"
        let l4 = packet[ihl...]
        guard l4.count >= 4 else { return nil }
        let l4Start = l4.startIndex
        let srcPort = (UInt16(l4[l4Start]) << 8) | UInt16(l4[l4Start + 1])
        let dstPort = (UInt16(l4[l4Start + 2]) << 8) | UInt16(l4[l4Start + 3])

        let local = direction == .outbound ? srcIP : dstIP
        let localPort = direction == .outbound ? srcPort : dstPort
        let remote = direction == .outbound ? dstIP : srcIP
        let remotePort = direction == .outbound ? dstPort : srcPort

        let key = FlowKey(
            localAddress: local,
            localPort: localPort,
            remoteAddress: remote,
            remotePort: remotePort,
            networkProtocol: proto,
            family: .ipv4
        )
        let payload = max(0, totalLen - ihl - (proto == 6 ? tcpHeaderLen(packet: packet, headerStart: ihl) : 8))
        return (key, payload)
    }

    private func parseIPv6(packet: Data, direction: FlowDirection) -> (FlowKey, Int)? {
        // IPv6 header is fixed 40 bytes.
        guard packet.count >= 40 else { return nil }
        let nextHeader = packet[6]
        // Only handle TCP/UDP directly. Extension headers (HBH, Routing,
        // Fragment, ...) get treated as unknown so the flow stays unkeyed.
        guard nextHeader == 6 || nextHeader == 17 else { return nil }

        let payloadLen = (Int(packet[4]) << 8) | Int(packet[5])
        let srcIP = formatIPv6(packet[8..<24])
        let dstIP = formatIPv6(packet[24..<40])
        let l4Start = 40
        guard packet.count >= l4Start + 4 else { return nil }
        let srcPort = (UInt16(packet[l4Start]) << 8) | UInt16(packet[l4Start + 1])
        let dstPort = (UInt16(packet[l4Start + 2]) << 8) | UInt16(packet[l4Start + 3])

        let local = direction == .outbound ? srcIP : dstIP
        let localPort = direction == .outbound ? srcPort : dstPort
        let remote = direction == .outbound ? dstIP : srcIP
        let remotePort = direction == .outbound ? dstPort : srcPort

        let key = FlowKey(
            localAddress: local,
            localPort: localPort,
            remoteAddress: remote,
            remotePort: remotePort,
            networkProtocol: nextHeader,
            family: .ipv6
        )
        let payload = max(0, payloadLen - (nextHeader == 6 ? tcpHeaderLen(packet: packet, headerStart: 40) : 8))
        return (key, payload)
    }

    /// TCP header is variable-length (data offset field). Returns 20 if the
    /// data offset is unparseable so we never under-count.
    private func tcpHeaderLen(packet: Data, headerStart: Int) -> Int {
        guard packet.count >= headerStart + 13 else { return 20 }
        let dataOffsetWords = (packet[headerStart + 12] >> 4) & 0x0F
        let len = Int(dataOffsetWords) * 4
        return len >= 20 ? len : 20
    }

    /// Compact-ish IPv6 string. Not RFC-5952 canonical; good enough for
    /// display + dictionary keying (same bytes always produce the same
    /// string).
    private func formatIPv6(_ bytes: Data) -> String {
        var groups: [String] = []
        groups.reserveCapacity(8)
        var idx = bytes.startIndex
        while idx < bytes.endIndex {
            let hi = bytes[idx]
            let lo = bytes[idx + 1]
            let word = (UInt16(hi) << 8) | UInt16(lo)
            groups.append(String(format: "%x", word))
            idx = bytes.index(idx, offsetBy: 2)
        }
        return groups.joined(separator: ":")
    }
}
