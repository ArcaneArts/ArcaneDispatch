// IPPacket.swift
//
// Header parsing + packet building + checksum helpers for the userspace
// flow forwarder. We only handle the headers we actually need to make
// HTTP/HTTPS/UDP traffic round-trip: IPv4 + TCP + UDP. IPv6 + ICMP go
// down a slow-path (dropped or unkeyed) so the fast path stays tight.
//
// All builders return fully-checksummed Data buffers ready to hand to
// `NEPacketTunnelFlow.writePackets`. Parsers are zero-copy and side-effect
// free; they hand back small structs the forwarder uses to decide what
// to do next.
//
// IMPORTANT: every multi-byte field on the wire is big-endian. The
// helpers below normalize to host byte order at the boundary so the
// rest of the forwarder can use plain Swift integers.

import Foundation

// MARK: - Constants

/// IPv4 protocol numbers we care about.
enum IPProto: UInt8 {
    case tcp = 6
    case udp = 17
}

/// TCP control flags we use to drive the per-flow state machine.
struct TCPFlags: OptionSet {
    let rawValue: UInt8
    static let fin = TCPFlags(rawValue: 0x01)
    static let syn = TCPFlags(rawValue: 0x02)
    static let rst = TCPFlags(rawValue: 0x04)
    static let psh = TCPFlags(rawValue: 0x08)
    static let ack = TCPFlags(rawValue: 0x10)
}

// MARK: - Parsed views

/// Parsed IPv4 header. Field-for-field, no payload.
struct IPv4Header {
    let totalLength: Int    // bytes (header + payload)
    let headerLength: Int   // bytes; IHL * 4
    let proto: UInt8
    let srcIP: UInt32       // host byte order
    let dstIP: UInt32       // host byte order
    let identification: UInt16
}

/// Parsed TCP header. No options — we just need the flow plumbing.
struct TCPHeader {
    let srcPort: UInt16
    let dstPort: UInt16
    let seq: UInt32
    let ack: UInt32
    let dataOffset: Int     // bytes; data offset * 4
    let flags: TCPFlags
    let windowSize: UInt16
}

/// Parsed UDP header.
struct UDPHeader {
    let srcPort: UInt16
    let dstPort: UInt16
    let length: UInt16      // includes the 8-byte header
}

// MARK: - Parsing

enum IPPacket {

    /// Parse an IPv4 header. Returns nil for IPv6, malformed packets, or
    /// packets shorter than their declared total length.
    static func parseIPv4(_ data: Data) -> IPv4Header? {
        guard data.count >= 20 else { return nil }
        let v0 = data[data.startIndex]
        guard (v0 >> 4) == 4 else { return nil }
        let ihl = Int(v0 & 0x0F) * 4
        guard ihl >= 20, data.count >= ihl else { return nil }
        let total = Int(u16(data, data.startIndex + 2))
        guard total >= ihl, data.count >= total else { return nil }
        let proto = data[data.startIndex + 9]
        let id = u16(data, data.startIndex + 4)
        let src = u32(data, data.startIndex + 12)
        let dst = u32(data, data.startIndex + 16)
        return IPv4Header(
            totalLength: total,
            headerLength: ihl,
            proto: proto,
            srcIP: src,
            dstIP: dst,
            identification: id)
    }

    /// Parse a TCP header that starts at `data[offset]`. Returns nil when
    /// the data offset field is malformed or the packet is truncated.
    static func parseTCP(_ data: Data, at offset: Int) -> TCPHeader? {
        guard data.count >= offset + 20 else { return nil }
        let base = data.startIndex + offset
        let sp = u16(data, base)
        let dp = u16(data, base + 2)
        let seq = u32(data, base + 4)
        let ack = u32(data, base + 8)
        let off = Int((data[base + 12] >> 4) & 0x0F) * 4
        guard off >= 20, data.count >= offset + off else { return nil }
        let flags = TCPFlags(rawValue: data[base + 13])
        let win = u16(data, base + 14)
        return TCPHeader(srcPort: sp, dstPort: dp, seq: seq, ack: ack,
                         dataOffset: off, flags: flags, windowSize: win)
    }

    /// Parse a UDP header that starts at `data[offset]`. Returns nil when
    /// the length field is bogus or the packet is truncated.
    static func parseUDP(_ data: Data, at offset: Int) -> UDPHeader? {
        guard data.count >= offset + 8 else { return nil }
        let base = data.startIndex + offset
        let sp = u16(data, base)
        let dp = u16(data, base + 2)
        let len = u16(data, base + 4)
        guard len >= 8 else { return nil }
        return UDPHeader(srcPort: sp, dstPort: dp, length: len)
    }

    // MARK: - Building

    /// Build a full IPv4+TCP packet with correct checksums, no options.
    /// Returns the byte buffer ready to hand to `writePackets`.
    ///
    /// All fields except the checksums are written verbatim, so callers
    /// must ensure they map to the host's view of the flow (e.g. for a
    /// reply packet, swap src/dst from the original).
    static func buildTCPPacket(
        srcIP: UInt32, dstIP: UInt32,
        srcPort: UInt16, dstPort: UInt16,
        seq: UInt32, ack: UInt32,
        flags: TCPFlags, window: UInt16,
        payload: Data,
        identification: UInt16
    ) -> Data {
        let tcpHeaderLen = 20
        let totalLen = 20 + tcpHeaderLen + payload.count
        var pkt = Data(count: totalLen)

        // --- IPv4 header ---
        pkt[0] = 0x45                                   // version=4, IHL=5
        pkt[1] = 0                                      // DSCP/ECN
        pkt[2] = UInt8((totalLen >> 8) & 0xFF)          // total length
        pkt[3] = UInt8(totalLen & 0xFF)
        pkt[4] = UInt8((identification >> 8) & 0xFF)
        pkt[5] = UInt8(identification & 0xFF)
        pkt[6] = 0x40                                   // flags=DF, frag off=0
        pkt[7] = 0x00
        pkt[8] = 64                                     // TTL
        pkt[9] = IPProto.tcp.rawValue
        // IP checksum slot is bytes 10/11; zero-filled until we compute it.
        writeU32(&pkt, at: 12, srcIP)
        writeU32(&pkt, at: 16, dstIP)

        // --- TCP header ---
        writeU16(&pkt, at: 20, srcPort)
        writeU16(&pkt, at: 22, dstPort)
        writeU32(&pkt, at: 24, seq)
        writeU32(&pkt, at: 28, ack)
        pkt[32] = 0x50                                  // data offset=5 (20B), reserved=0
        pkt[33] = flags.rawValue
        writeU16(&pkt, at: 34, window)
        // TCP checksum slot at 36/37, urgent ptr at 38/39 (both zero for now).

        // --- Payload ---
        if !payload.isEmpty {
            pkt.replaceSubrange(40..<40 + payload.count, with: payload)
        }

        // --- TCP checksum (over pseudo-header + TCP header + payload) ---
        let tcpSum = tcpChecksum(srcIP: srcIP, dstIP: dstIP,
                                 segment: pkt[20...])
        writeU16(&pkt, at: 36, tcpSum)

        // --- IP checksum (over the 20-byte header, with cksum field = 0) ---
        let ipSum = ipChecksum(pkt[0..<20])
        writeU16(&pkt, at: 10, ipSum)

        return pkt
    }

    /// Build a full IPv4+UDP packet with correct checksums.
    static func buildUDPPacket(
        srcIP: UInt32, dstIP: UInt32,
        srcPort: UInt16, dstPort: UInt16,
        payload: Data,
        identification: UInt16
    ) -> Data {
        let udpLen = 8 + payload.count
        let totalLen = 20 + udpLen
        var pkt = Data(count: totalLen)

        // --- IPv4 header ---
        pkt[0] = 0x45
        pkt[1] = 0
        pkt[2] = UInt8((totalLen >> 8) & 0xFF)
        pkt[3] = UInt8(totalLen & 0xFF)
        pkt[4] = UInt8((identification >> 8) & 0xFF)
        pkt[5] = UInt8(identification & 0xFF)
        pkt[6] = 0x40
        pkt[7] = 0x00
        pkt[8] = 64
        pkt[9] = IPProto.udp.rawValue
        writeU32(&pkt, at: 12, srcIP)
        writeU32(&pkt, at: 16, dstIP)

        // --- UDP header ---
        writeU16(&pkt, at: 20, srcPort)
        writeU16(&pkt, at: 22, dstPort)
        writeU16(&pkt, at: 24, UInt16(udpLen))
        // UDP checksum slot at 26/27 (zero-fill, then compute).

        // --- Payload ---
        if !payload.isEmpty {
            pkt.replaceSubrange(28..<28 + payload.count, with: payload)
        }

        // --- UDP checksum ---
        let udpSum = udpChecksum(srcIP: srcIP, dstIP: dstIP,
                                 segment: pkt[20...])
        writeU16(&pkt, at: 26, udpSum)

        // --- IP checksum ---
        let ipSum = ipChecksum(pkt[0..<20])
        writeU16(&pkt, at: 10, ipSum)

        return pkt
    }

    // MARK: - Checksums

    /// 16-bit ones-complement sum over the IP header (RFC 791). The
    /// checksum field must be zero-filled before this is called.
    static func ipChecksum(_ slice: Data) -> UInt16 {
        return onesComplement16(slice)
    }

    /// TCP checksum = ones-complement sum of (pseudo-header || TCP segment).
    /// Pseudo-header is 12 bytes: srcIP, dstIP, zero, proto, TCP length.
    static func tcpChecksum(srcIP: UInt32, dstIP: UInt32, segment: Data) -> UInt16 {
        var pseudo = Data(count: 12)
        writeU32(&pseudo, at: 0, srcIP)
        writeU32(&pseudo, at: 4, dstIP)
        pseudo[8] = 0
        pseudo[9] = IPProto.tcp.rawValue
        writeU16(&pseudo, at: 10, UInt16(segment.count))
        var sum: UInt32 = 0
        sum = sumOnesComplement(sum: sum, data: pseudo)
        sum = sumOnesComplement(sum: sum, data: segment)
        return foldOnesComplement(sum)
    }

    /// UDP checksum = ones-complement sum of (pseudo-header || UDP segment).
    /// RFC 768 lets us skip it (write 0) but most stacks expect it; we
    /// always emit a correct one.
    static func udpChecksum(srcIP: UInt32, dstIP: UInt32, segment: Data) -> UInt16 {
        var pseudo = Data(count: 12)
        writeU32(&pseudo, at: 0, srcIP)
        writeU32(&pseudo, at: 4, dstIP)
        pseudo[8] = 0
        pseudo[9] = IPProto.udp.rawValue
        writeU16(&pseudo, at: 10, UInt16(segment.count))
        var sum: UInt32 = 0
        sum = sumOnesComplement(sum: sum, data: pseudo)
        sum = sumOnesComplement(sum: sum, data: segment)
        let folded = foldOnesComplement(sum)
        // RFC 768: a UDP cksum of all-zero on the wire means "no
        // checksum"; if the computed value is 0, replace with 0xFFFF.
        return folded == 0 ? 0xFFFF : folded
    }

    // MARK: - Address helpers

    /// `192.168.1.45` → 0xC0A8012D (host byte order).
    static func parseIPv4Address(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var out: UInt32 = 0
        for p in parts {
            guard let v = UInt8(p) else { return nil }
            out = (out << 8) | UInt32(v)
        }
        return out
    }

    /// Inverse of [parseIPv4Address].
    static func formatIPv4Address(_ ip: UInt32) -> String {
        return "\(UInt8((ip >> 24) & 0xFF)).\(UInt8((ip >> 16) & 0xFF)).\(UInt8((ip >> 8) & 0xFF)).\(UInt8(ip & 0xFF))"
    }
}

// MARK: - Byte order helpers (file-private)

private func u16(_ d: Data, _ idx: Int) -> UInt16 {
    return (UInt16(d[idx]) << 8) | UInt16(d[idx + 1])
}

private func u32(_ d: Data, _ idx: Int) -> UInt32 {
    return (UInt32(d[idx]) << 24)
         | (UInt32(d[idx + 1]) << 16)
         | (UInt32(d[idx + 2]) << 8)
         | UInt32(d[idx + 3])
}

private func writeU16(_ d: inout Data, at idx: Int, _ v: UInt16) {
    d[idx] = UInt8((v >> 8) & 0xFF)
    d[idx + 1] = UInt8(v & 0xFF)
}

private func writeU32(_ d: inout Data, at idx: Int, _ v: UInt32) {
    d[idx] = UInt8((v >> 24) & 0xFF)
    d[idx + 1] = UInt8((v >> 16) & 0xFF)
    d[idx + 2] = UInt8((v >> 8) & 0xFF)
    d[idx + 3] = UInt8(v & 0xFF)
}

/// Sum 16-bit big-endian words; carry-folds at the end.
private func onesComplement16(_ data: Data) -> UInt16 {
    var sum: UInt32 = 0
    sum = sumOnesComplement(sum: sum, data: data)
    return foldOnesComplement(sum)
}

private func sumOnesComplement(sum initial: UInt32, data: Data) -> UInt32 {
    var sum = initial
    var i = data.startIndex
    let end = data.endIndex
    while i < end - 1 {
        sum &+= (UInt32(data[i]) << 8) | UInt32(data[i + 1])
        i += 2
    }
    if i < end {
        // Odd byte at the end — pad on the right with zero.
        sum &+= UInt32(data[i]) << 8
    }
    return sum
}

private func foldOnesComplement(_ sum: UInt32) -> UInt16 {
    var s = sum
    while (s >> 16) != 0 {
        s = (s & 0xFFFF) + (s >> 16)
    }
    return ~UInt16(s & 0xFFFF)
}
