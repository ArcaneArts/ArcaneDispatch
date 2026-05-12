// FlowForwarder.swift
//
// Userspace TCP+UDP forwarder for the macOS Network Extension. Bridges
// raw IP packets from `NEPacketTunnelFlow.readPackets` to real-world
// destinations via `NWConnection`, then synthesizes reply packets back
// into the TUN.
//
// Architecture:
//
//   readPackets ──► parse ──► route to flow ──► NWConnection.send
//                                                     │
//                                                     ▼
//                                              NWConnection.receive
//                                                     │
//                                                     ▼
//                                          build reply packet ──► writePackets
//
// Per-flow state lives in [FlowProxy] (TCP) and [UDPFlowProxy]. The
// state machines are deliberately minimal — we lean on the OS' real TCP
// stack on the connection side and just translate to/from packets on
// the TUN side.
//
// We DO maintain the TUN-side TCP state machine because the local app
// is talking real TCP to us; the OS isn't going to help with that. The
// implementation handles:
//
//   * SYN handshake — synthesize SYN-ACK after NWConnection is ready,
//     accept the final ACK.
//   * Steady-state — pipe bytes both ways, ACK new data, track seq nums.
//   * FIN handshake — relay close in both directions.
//   * RST — tear down the flow without ceremony.
//
// What we deliberately DO NOT do (yet):
//
//   * Out-of-order packet reassembly (we just drop and let the app's TCP
//     stack retransmit). Most modern stacks recover gracefully.
//   * Selective ACKs.
//   * Window scaling — we advertise a generous window and ignore the
//     peer's scale factor, which works because we read every NWConnection
//     receive immediately.
//   * IPv6 — only IPv4 for now; the OS' default route will still send
//     v6 packets through us but we drop them silently. Most internet
//     traffic still fails over to v4 in seconds.

import Foundation
import Network
import NetworkExtension
import OSLog

final class FlowForwarder {
    private let log = Logger(subsystem: "art.arcane.dispatch.tunnel", category: "fwd")
    private let packetFlow: NEPacketTunnelFlow
    private let queue: DispatchQueue
    /// Per-link `NWInterface` for outbound binding. Keyed by linkId
    /// (matches `PolicyEngine` decisions). When the link's interface is
    /// unknown we don't restrict — `NWConnection` falls back to the OS'
    /// chosen route, which still works but doesn't honor the bond.
    private var linkInterfaces: [String: NWInterface] = [:]
    /// Cached link → BSD device map for log/debug.
    private var linkBSDs: [String: String] = [:]

    private var tcpFlows: [FlowKey: TCPFlowProxy] = [:]
    private var udpFlows: [FlowKey: UDPFlowProxy] = [:]

    /// Throughput accumulator: bytes per link per direction, since last
    /// drain. The pump drains this on a timer to publish `LinkMetric`
    /// samples to the Dart side.
    private var bytesInWindow: [String: Int] = [:]    // link → bytes received from network
    private var bytesOutWindow: [String: Int] = [:]   // link → bytes sent toward network

    init(packetFlow: NEPacketTunnelFlow, queue: DispatchQueue) {
        self.packetFlow = packetFlow
        self.queue = queue
    }

    /// Refresh the per-link `NWInterface` map. Call this whenever the
    /// policy or interface snapshot changes so new flows bind to the
    /// right outbound interface.
    func setLinkInterfaces(_ map: [String: NWInterface], bsdMap: [String: String]) {
        linkInterfaces = map
        linkBSDs = bsdMap
    }

    /// Drain the throughput accumulators. Returns `linkId → (in, out)`
    /// since the previous drain.
    func drainThroughput() -> [String: (inBytes: Int, outBytes: Int)] {
        var out: [String: (Int, Int)] = [:]
        for (id, bytes) in bytesInWindow {
            out[id] = (bytes, out[id]?.1 ?? 0)
        }
        for (id, bytes) in bytesOutWindow {
            let existing = out[id] ?? (0, 0)
            out[id] = (existing.0, existing.1 + bytes)
        }
        bytesInWindow.removeAll(keepingCapacity: true)
        bytesOutWindow.removeAll(keepingCapacity: true)
        return out
    }

    /// Process one outbound packet from the TUN. `linkId` is whatever the
    /// policy decided for this flow's 5-tuple — we use it to bind new
    /// NWConnections to the link's preferred interface.
    func forward(packet: Data, linkId: String) {
        // Only handle IPv4 for now. IPv6 gets silently dropped, which
        // is fine because dual-stack apps fall back to v4.
        guard let ip = IPPacket.parseIPv4(packet) else { return }

        switch ip.proto {
        case IPProto.tcp.rawValue:
            handleTCP(ip: ip, packet: packet, linkId: linkId)
        case IPProto.udp.rawValue:
            handleUDP(ip: ip, packet: packet, linkId: linkId)
        default:
            // ICMP, IGMP, etc. — drop. The user-visible effect is no
            // ping over the tunnel, which is an acceptable Phase-7 trade.
            return
        }
    }

    /// Tear every flow down. Called from `PacketPump.stop`.
    func shutdown() {
        for proxy in tcpFlows.values { proxy.cancel() }
        for proxy in udpFlows.values { proxy.cancel() }
        tcpFlows.removeAll()
        udpFlows.removeAll()
    }

    // MARK: - TCP

    private func handleTCP(ip: IPv4Header, packet: Data, linkId: String) {
        guard let tcp = IPPacket.parseTCP(packet, at: ip.headerLength) else {
            return
        }
        let payloadStart = ip.headerLength + tcp.dataOffset
        let payloadLen = ip.totalLength - payloadStart
        let payload = payloadLen > 0
            ? packet.subdata(in: (packet.startIndex + payloadStart)..<(packet.startIndex + payloadStart + payloadLen))
            : Data()

        // Build key from outbound perspective: local=src, remote=dst.
        let key = FlowKey(
            localAddress: IPPacket.formatIPv4Address(ip.srcIP),
            localPort: tcp.srcPort,
            remoteAddress: IPPacket.formatIPv4Address(ip.dstIP),
            remotePort: tcp.dstPort,
            networkProtocol: IPProto.tcp.rawValue,
            family: .ipv4)

        if let existing = tcpFlows[key] {
            existing.handleOutbound(ip: ip, tcp: tcp, payload: payload)
            if payloadLen > 0 {
                bytesOutWindow[linkId, default: 0] += payloadLen
            }
            return
        }

        // New flow. Only act on SYN (start-of-connection); a stray ACK
        // for a flow we don't know about is dropped silently — the app's
        // TCP stack will retransmit a SYN on retry.
        guard tcp.flags.contains(.syn) else { return }

        let nwInterface = linkInterfaces[linkId]
        let proxy = TCPFlowProxy(
            key: key,
            initialClientSeq: tcp.seq,
            clientWindow: tcp.windowSize,
            requiredInterface: nwInterface,
            queue: queue,
            packetFlow: packetFlow,
            onClose: { [weak self] k in self?.tcpFlows.removeValue(forKey: k) },
            onBytes: { [weak self] bin, bout in
                if bin > 0 { self?.bytesInWindow[linkId, default: 0] += bin }
                if bout > 0 { self?.bytesOutWindow[linkId, default: 0] += bout }
            })
        tcpFlows[key] = proxy
        proxy.start()
    }

    // MARK: - UDP

    private func handleUDP(ip: IPv4Header, packet: Data, linkId: String) {
        guard let udp = IPPacket.parseUDP(packet, at: ip.headerLength) else {
            return
        }
        let payloadStart = ip.headerLength + 8
        let payloadLen = Int(udp.length) - 8
        guard payloadLen > 0,
              packet.count >= payloadStart + payloadLen else { return }
        let payload = packet.subdata(
            in: (packet.startIndex + payloadStart)..<(packet.startIndex + payloadStart + payloadLen))

        let key = FlowKey(
            localAddress: IPPacket.formatIPv4Address(ip.srcIP),
            localPort: udp.srcPort,
            remoteAddress: IPPacket.formatIPv4Address(ip.dstIP),
            remotePort: udp.dstPort,
            networkProtocol: IPProto.udp.rawValue,
            family: .ipv4)

        if let existing = udpFlows[key] {
            existing.sendOutbound(payload)
            bytesOutWindow[linkId, default: 0] += payloadLen
            return
        }

        let nwInterface = linkInterfaces[linkId]
        let proxy = UDPFlowProxy(
            key: key,
            requiredInterface: nwInterface,
            queue: queue,
            packetFlow: packetFlow,
            onClose: { [weak self] k in self?.udpFlows.removeValue(forKey: k) },
            onBytes: { [weak self] bin, bout in
                if bin > 0 { self?.bytesInWindow[linkId, default: 0] += bin }
                if bout > 0 { self?.bytesOutWindow[linkId, default: 0] += bout }
            })
        udpFlows[key] = proxy
        proxy.start(initialPayload: payload)
        bytesOutWindow[linkId, default: 0] += payloadLen
    }
}

// =============================================================================
// MARK: - TCPFlowProxy

/// Single TCP flow's state. Lives entirely on `queue` (which the
/// forwarder pins). Owns one `NWConnection` to the remote, plus the
/// sequence-number bookkeeping for the TUN-side conversation.
private final class TCPFlowProxy {
    private let log = Logger(subsystem: "art.arcane.dispatch.tunnel", category: "tcp")
    private let key: FlowKey
    private let queue: DispatchQueue
    private let packetFlow: NEPacketTunnelFlow
    private let connection: NWConnection
    private let onClose: (FlowKey) -> Void
    /// Called with `(inBytes, outBytes)` for each chunk we move so the
    /// forwarder can update per-link throughput accumulators.
    private let onBytes: (Int, Int) -> Void

    /// Pre-parsed addresses for fast reply-packet builds.
    private let srcIP: UInt32       // remote (network side) → goes in reply src
    private let dstIP: UInt32       // local (TUN side) → goes in reply dst

    // --- TCP state ---

    /// Sequence number space we'll use for *our* (the simulated server's)
    /// side of the conversation. Random initial value per RFC 6528 so an
    /// app restarted right after a previous flow doesn't get confused.
    private var ourSeq: UInt32 = UInt32.random(in: 1...UInt32.max)
    /// What we've ACKed from the client. Initially `clientISN + 1` after
    /// we see the SYN. Bumps by `payload.count` for each in-order segment.
    private var clientNextSeq: UInt32
    /// What the client has ACKed of our sent data. Used to detect when
    /// we can forget delivered bytes.
    private var clientAckedToUs: UInt32 = 0
    /// Window size we advertise to the client (constant; we drain fast).
    private let advWindow: UInt16 = 0xFFFF
    /// Identification field counter for IP headers.
    private var ipId: UInt16 = UInt16.random(in: 0...UInt16.max)

    private enum State {
        case synReceived    // we've seen the client's SYN, NWConnection starting
        case established
        case finWait        // client sent FIN; waiting for connection to drain
        case closing
        case closed
    }
    private var state: State = .synReceived

    init(key: FlowKey,
         initialClientSeq: UInt32,
         clientWindow: UInt16,
         requiredInterface: NWInterface?,
         queue: DispatchQueue,
         packetFlow: NEPacketTunnelFlow,
         onClose: @escaping (FlowKey) -> Void,
         onBytes: @escaping (Int, Int) -> Void) {
        self.key = key
        self.queue = queue
        self.packetFlow = packetFlow
        self.onClose = onClose
        self.onBytes = onBytes
        // The TUN-side reply packets are FROM the remote (network) TO the
        // local app. So src in our packet is the remote IP, dst is the
        // local IP.
        self.srcIP = IPPacket.parseIPv4Address(key.remoteAddress) ?? 0
        self.dstIP = IPPacket.parseIPv4Address(key.localAddress) ?? 0
        // We'll ACK initialClientSeq + 1 (SYN counts as 1 byte of sequence space).
        self.clientNextSeq = initialClientSeq &+ 1

        let host = NWEndpoint.Host(key.remoteAddress)
        let port = NWEndpoint.Port(integerLiteral: key.remotePort)
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        if let iface = requiredInterface {
            params.requiredInterface = iface
        }
        // Skip OS-level proxy resolution; we're already the tunnel.
        params.preferNoProxies = true
        self.connection = NWConnection(host: host, port: port, using: params)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state)
        }
        connection.start(queue: queue)
    }

    func cancel() {
        if state != .closed {
            state = .closed
            connection.cancel()
            // Send a synthetic RST to clean up the TUN side too, in
            // case the kernel still has half-open state.
            sendPacket(flags: [.rst, .ack], payload: Data())
            onClose(key)
        }
    }

    func handleOutbound(ip: IPv4Header, tcp: TCPHeader, payload: Data) {
        if tcp.flags.contains(.rst) {
            state = .closed
            connection.cancel()
            onClose(key)
            return
        }

        // Drop stale segments (out-of-order). The app's TCP stack will
        // retransmit. Trying to reassemble in userspace is the road
        // to madness.
        if tcp.seq != clientNextSeq && !payload.isEmpty {
            // Could be a retransmit of an already-ACKed chunk; ACK again
            // so the client stops resending.
            if tcp.seq &+ UInt32(payload.count) <= clientNextSeq {
                sendPacket(flags: [.ack], payload: Data())
            }
            return
        }

        // Update what we've ACKed if the client confirmed bytes we sent.
        if tcp.flags.contains(.ack) {
            clientAckedToUs = tcp.ack
        }

        // FIN handling — we count the FIN as 1 byte of sequence space.
        if tcp.flags.contains(.fin) {
            clientNextSeq &+= 1
            state = .finWait
            // ACK the FIN immediately, then close the outbound connection.
            sendPacket(flags: [.ack], payload: Data())
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.queue.async {
                    self?.connection.cancel()
                }
            })
            return
        }

        // Stream payload to the remote.
        if !payload.isEmpty {
            clientNextSeq &+= UInt32(payload.count)
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error = error {
                    self.log.error("send err: \(String(describing: error), privacy: .public)")
                    self.cancel()
                    return
                }
                // ACK the client's data so it can free its send buffer.
                self.sendPacket(flags: [.ack], payload: Data())
            })
        }
    }

    private func handleConnectionState(_ s: NWConnection.State) {
        switch s {
        case .ready:
            // Send SYN-ACK to the TUN. seq = ourSeq, ack = clientISN+1.
            // SYN consumes 1 byte of our sequence space.
            sendPacket(flags: [.syn, .ack], payload: Data())
            ourSeq &+= 1
            state = .established
            // Start the inbound read loop.
            readFromConnection()
        case .failed(let error):
            log.warning("conn failed: \(String(describing: error), privacy: .public)")
            // Send RST so the app doesn't hang on a half-open connection.
            sendPacket(flags: [.rst, .ack], payload: Data())
            state = .closed
            onClose(key)
        case .cancelled:
            if state != .closed {
                // Send FIN to flush the TUN side. We'll go to closing.
                sendPacket(flags: [.fin, .ack], payload: Data())
                ourSeq &+= 1
                state = .closing
            }
            // Best-effort: clean up after a short grace period.
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                if self.state != .closed {
                    self.state = .closed
                    self.onClose(self.key)
                }
            }
        default:
            break
        }
    }

    private func readFromConnection() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error = error {
                self.log.warning("recv err: \(String(describing: error), privacy: .public)")
                self.cancel()
                return
            }
            if let data = data, !data.isEmpty {
                // Send to TUN as one or more TCP segments. We chunk at
                // 1380 bytes to stay safely under typical MTU.
                let mss = 1380
                var offset = 0
                while offset < data.count {
                    let end = min(offset + mss, data.count)
                    let segment = data.subdata(in: offset..<end)
                    self.sendPacket(flags: [.psh, .ack], payload: segment)
                    self.ourSeq &+= UInt32(segment.count)
                    offset = end
                }
                self.onBytes(data.count, 0)
            }
            if isComplete {
                // Server closed. Send FIN to the TUN.
                self.sendPacket(flags: [.fin, .ack], payload: Data())
                self.ourSeq &+= 1
                self.state = .closing
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self else { return }
                    self.state = .closed
                    self.onClose(self.key)
                }
                return
            }
            // Re-arm.
            self.readFromConnection()
        }
    }

    /// Build + write one packet back to the TUN with the current seq/ack
    /// numbers. Bumps `ipId` so each packet gets a unique IP id.
    private func sendPacket(flags: TCPFlags, payload: Data) {
        let pkt = IPPacket.buildTCPPacket(
            srcIP: srcIP, dstIP: dstIP,
            srcPort: key.remotePort, dstPort: key.localPort,
            seq: ourSeq, ack: clientNextSeq,
            flags: flags, window: advWindow,
            payload: payload,
            identification: ipId)
        ipId &+= 1
        packetFlow.writePackets([pkt], withProtocols: [NSNumber(value: AF_INET)])
    }
}

// =============================================================================
// MARK: - UDPFlowProxy

/// Single UDP flow. Much simpler than TCP — stateless on the wire, so we
/// just keep one NWConnection (.udp) open and shuttle datagrams.
private final class UDPFlowProxy {
    private let log = Logger(subsystem: "art.arcane.dispatch.tunnel", category: "udp")
    private let key: FlowKey
    private let queue: DispatchQueue
    private let packetFlow: NEPacketTunnelFlow
    private let connection: NWConnection
    private let onClose: (FlowKey) -> Void
    private let onBytes: (Int, Int) -> Void
    private let srcIP: UInt32
    private let dstIP: UInt32
    private var ipId: UInt16 = UInt16.random(in: 0...UInt16.max)
    /// Idle timeout — drop UDP flows we haven't seen activity on in 30 s.
    private var idleTimer: DispatchSourceTimer?
    private static let idleTimeout: TimeInterval = 30

    init(key: FlowKey,
         requiredInterface: NWInterface?,
         queue: DispatchQueue,
         packetFlow: NEPacketTunnelFlow,
         onClose: @escaping (FlowKey) -> Void,
         onBytes: @escaping (Int, Int) -> Void) {
        self.key = key
        self.queue = queue
        self.packetFlow = packetFlow
        self.onClose = onClose
        self.onBytes = onBytes
        self.srcIP = IPPacket.parseIPv4Address(key.remoteAddress) ?? 0
        self.dstIP = IPPacket.parseIPv4Address(key.localAddress) ?? 0

        let host = NWEndpoint.Host(key.remoteAddress)
        let port = NWEndpoint.Port(integerLiteral: key.remotePort)
        let params = NWParameters.udp
        params.includePeerToPeer = false
        if let iface = requiredInterface {
            params.requiredInterface = iface
        }
        params.preferNoProxies = true
        self.connection = NWConnection(host: host, port: port, using: params)
    }

    func start(initialPayload: Data) {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, initialPayload: initialPayload)
        }
        connection.start(queue: queue)
    }

    func cancel() {
        idleTimer?.cancel()
        idleTimer = nil
        connection.cancel()
        onClose(key)
    }

    /// Forward a datagram from the TUN to the network.
    func sendOutbound(_ payload: Data) {
        bumpIdleTimer()
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.log.warning("udp send err: \(String(describing: error), privacy: .public)")
                self?.cancel()
            }
        })
    }

    private func handleConnectionState(_ s: NWConnection.State, initialPayload: Data) {
        switch s {
        case .ready:
            bumpIdleTimer()
            // Flush the initial payload (the one that opened the flow).
            connection.send(content: initialPayload, completion: .contentProcessed { _ in })
            readFromConnection()
        case .failed(let error):
            log.warning("udp failed: \(String(describing: error), privacy: .public)")
            cancel()
        case .cancelled:
            cancel()
        default:
            break
        }
    }

    private func readFromConnection() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error = error {
                self.log.warning("udp recv err: \(String(describing: error), privacy: .public)")
                self.cancel()
                return
            }
            if let data = data, !data.isEmpty {
                let pkt = IPPacket.buildUDPPacket(
                    srcIP: self.srcIP, dstIP: self.dstIP,
                    srcPort: self.key.remotePort, dstPort: self.key.localPort,
                    payload: data,
                    identification: self.ipId)
                self.ipId &+= 1
                self.packetFlow.writePackets([pkt], withProtocols: [NSNumber(value: AF_INET)])
                self.onBytes(data.count, 0)
                self.bumpIdleTimer()
            }
            self.readFromConnection()
        }
    }

    private func bumpIdleTimer() {
        idleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.idleTimeout)
        t.setEventHandler { [weak self] in self?.cancel() }
        t.resume()
        idleTimer = t
    }
}
