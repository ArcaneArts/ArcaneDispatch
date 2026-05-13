// PacketPump.swift
//
// Reads packets from the macOS TUN (`packetFlow.readPackets`), classifies them
// by 5-tuple via `FlowTracker`, picks an outbound link via the same
// `PolicyEngine` the Dart UI shows, and forwards via the per-link
// source-address dispatch.
//
// Phase 6 scope (this iteration):
// * Run the policy engine per-packet to pick a link.
// * Maintain per-flow stickiness in `FlowTracker` so the UI shows stable
//   link assignments.
// * Honor kill-switch semantics: when the engine reports no eligible links
//   and `killSwitch` is on, every outbound packet is dropped.
//
// Relay mode sends packets through `BondedClient` and
// `BondedSocketPool`, then writes relay replies back into the TUN.

import Foundation
import Network
import NetworkExtension
import OSLog

/// Owns the read/write loop on `NEPacketTunnelFlow`. Re-entrant `start()`/
/// `stop()` is intentional so `PacketTunnelProvider` can swap us out cleanly
/// during Wi-Fi handoff.
final class PacketPump {
    private let log = Logger(subsystem: "art.arcane.dispatch.tunnel", category: "pump")
    private let packetFlow: NEPacketTunnelFlow
    private let queue = DispatchQueue(label: "art.arcane.dispatch.tunnel.pump", qos: .userInitiated)
    private let engine = PolicyEngine()
    private var tracker: FlowTracker!
    private let forwarder: FlowForwarder
    /// Cached BSD device name → `NWInterface` for outbound link binding.
    /// Refreshed on every policy/metric update via `NWPathMonitor`.
    private var bsdToInterface: [String: NWInterface] = [:]
    /// Long-lived monitor that feeds [bsdToInterface]. Kept here so a
    /// single monitor covers the whole pump's lifetime.
    private let pathMonitor = NWPathMonitor()
    private var policy: ExtensionPolicy
    /// Cached decision from the most recent `applyPolicy`. Re-evaluated only
    /// on policy reload — per-packet evaluation is too hot a path for the
    /// engine, and the engine's output only depends on policy + (slow) metrics.
    private var decision: PolicyDecision = PolicyDecision(eligible: [], ineligible: [], activeGroup: nil)
    /// Live per-link RTT/loss snapshot. Phase 6 leaves this empty since the
    /// probe service still lives in the container app; Phase 7 will start
    /// populating it from in-tunnel keepalives.
    private var metrics: [String: LinkMetricSample] = [:]
    private var running = false
    private var sweepTimer: DispatchSourceTimer?

    /// Sticky-flow cursor. Index into the engine's eligible list, advanced
    /// per new flow so we get weighted-RR across flows (not packets).
    private var rrCursor: Int = 0

    /// Phase 7 bonded-transport client. Lazily built when
    /// `policy.bondedTransport == true`. The instance is rebuilt whenever
    /// the eligible link set changes so the scheduler always has up-to-date
    /// link states. Set to `nil` when the flag is off so the encoder
    /// allocations don't fire on hot paths.
    private var bondedClient: BondedClient?
    /// Stable u16 wire id per link, deterministic from link insertion order.
    /// Wraps at u16 — Phase 7 callers are bound by `kBondedMaxPayload` and
    /// the protocol caps the link count well below 2^16.
    private var bondedWireIds: [String: UInt16] = [:]
    private var bondedSocketPool: BondedSocketPool?
    private var bondedRelayEndpoint: BondedRelayEndpoint?

    init(packetFlow: NEPacketTunnelFlow, policy: ExtensionPolicy) {
        self.packetFlow = packetFlow
        self.policy = policy
        self.forwarder = FlowForwarder(packetFlow: packetFlow, queue: queue)
        self.tracker = FlowTracker()
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.running { return }
            self.running = true
            self.decision = self.engine.evaluate(policy: self.policy, metrics: self.metrics)
            self.rebuildBondedClientIfNeeded()
            self.scheduleSweep()
            self.startPathMonitor()
            self.rebuildLinkInterfaces()
            self.log.info("PacketPump: starting (eligible=\(self.decision.eligible.count), group=\(String(describing: self.decision.activeGroup)), bonded=\(self.policy.bondedTransport ?? false))")
            self.readLoop()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.log.info("PacketPump: stopping")
            self.running = false
            self.sweepTimer?.cancel()
            self.sweepTimer = nil
            self.pathMonitor.cancel()
            self.forwarder.shutdown()
            self.bondedClient?.dispose()
            self.bondedClient = nil
            self.bondedSocketPool?.close()
            self.bondedSocketPool = nil
            self.bondedRelayEndpoint = nil
        }
    }

    /// Apply a refreshed policy without restarting the tunnel. Called when the
    /// container app sends a `reloadPolicy` `handleAppMessage`.
    func applyPolicy(_ next: ExtensionPolicy) {
        queue.async { [weak self] in
            guard let self else { return }
            self.policy = next
            self.decision = self.engine.evaluate(policy: next, metrics: self.metrics)
            self.rrCursor = 0
            self.rebuildBondedClientIfNeeded()
            self.rebuildLinkInterfaces()
            self.log.info("PacketPump: policy applied (\(next.links.count) links, \(self.decision.eligible.count) eligible, bonded=\(next.bondedTransport ?? false))")
        }
    }

    /// Push the latest probe metrics into the engine. Phase 6 has nobody
    /// calling this yet; in Phase 7 the bonded transport's keepalive will.
    func applyMetrics(_ next: [String: LinkMetricSample]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.metrics = next
            self.decision = self.engine.evaluate(policy: self.policy, metrics: next)
            self.rebuildBondedClientIfNeeded()
        }
    }

    /// Recursive packet read loop — `readPackets` calls back asynchronously
    /// with the next batch. We re-arm immediately to keep the kernel queue
    /// drained.
    private func readLoop() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                self.handle(packets: packets, protocols: protocols)
                self.readLoop()
            }
        }
    }

    private func handle(packets: [Data], protocols: [NSNumber]) {
        // Phase 4-on-tunnel kill switch: no eligible link + kill switch on =
        // drop everything outbound. The UI banner already reflects this; the
        // packet pump just needs to honor it.
        if !decision.hasEligible {
            if policy.killSwitch {
                // Drop packets silently. Counters could go here later.
                return
            }
            // Even without kill switch we have nowhere to send the packet —
            // there's no fallback path until Phase 7 wires the bonded
            // scheduler. For now, drop with a log.
            log.warning("no eligible links — dropping \(packets.count) packets")
            return
        }

        for packet in packets {
            // Observe — this both classifies and bookkeeps the flow,
            // and returns the assigned link via [assignLink].
            let flow = tracker.observe(packet: packet, direction: .outbound) { [weak self] _ in
                return self?.assignLink() ?? ""
            }
            let linkId = flow?.linkId ?? assignLink()
            if let client = bondedClient, bondedRelayEndpoint != nil {
                client.send(packet)
                continue
            }

            forwarder.forward(packet: packet, linkId: linkId)
            if let client = bondedClient {
                // No relay endpoint is configured. Keep the bonded encoder
                // as a local diagnostics mirror, but let FlowForwarder carry
                // traffic so the tunnel remains usable.
                client.send(packet)
            }
        }
    }

    /// Pick a link for a new flow. Sticky-RR over the engine's eligible
    /// set; the cursor only advances on new flows so an existing flow's
    /// link stays pinned for its entire life (Phase 6 contract — Phase 7
    /// can override this on a per-packet basis for true bonded mode).
    private func assignLink() -> String {
        guard !decision.eligible.isEmpty else { return "" }
        let idx = rrCursor % decision.eligible.count
        rrCursor &+= 1
        return decision.eligible[idx].link.id
    }

    /// (Re)build the bonded client when the debug flag changes, or refresh
    /// its scheduler state when only the eligible link set changed. Runs
    /// on `queue` — never call directly from outside the pump.
    ///
    private func rebuildBondedClientIfNeeded() {
        let endpoint = BondedRelayEndpoint.parse(policy.serverUrl)
        let wantBonded = (policy.bondedTransport ?? false) || endpoint != nil
        if !wantBonded {
            if let existing = bondedClient {
                existing.dispose()
                bondedClient = nil
                bondedWireIds.removeAll()
                log.info("bonded transport disabled — encoder torn down")
            }
            bondedSocketPool?.close()
            bondedSocketPool = nil
            bondedRelayEndpoint = nil
            return
        }
        // Build a deterministic wireId mapping from the engine's eligible
        // order. We add new ids as links appear and never reassign existing
        // ones for the lifetime of this pump instance.
        var nextWireId: UInt16 = UInt16(bondedWireIds.count)
        for decisionLink in decision.eligible {
            let id = decisionLink.link.id
            if bondedWireIds[id] == nil {
                bondedWireIds[id] = nextWireId
                nextWireId &+= 1
            }
        }
        // Build per-link scheduler state from the decision + latest metric.
        // We feed the engine's already-resolved weight + priority directly so
        // the bonded scheduler agrees with the legacy per-flow forwarder on
        // which links count. Bandwidth isn't probed yet (Phase 7 keepalives
        // will start populating it); the bonded scheduler's 1 Mbps default
        // is fine until then.
        let states: [BondedLinkState] = decision.eligible.map { dl in
            let m = metrics[dl.link.id]
            return BondedLinkState(
                linkId: dl.link.id,
                wireId: bondedWireIds[dl.link.id] ?? 0,
                priority: bondedPriority(dl.sourcePriority),
                status: .healthy,
                weight: dl.weight,
                rttMs: m?.rttMs ?? 50.0,
                lossFraction: m?.loss ?? 0.0
            )
        }
        // Map the policy's bonding mode to the bonded layer enum.
        let mode = bondedMode(policy.mode)
        if endpoint != bondedRelayEndpoint {
            bondedSocketPool?.close()
            bondedSocketPool = nil
            bondedRelayEndpoint = endpoint
            if let endpoint {
                bondedSocketPool = BondedSocketPool(
                    endpoint: endpoint,
                    queue: queue,
                    inbound: { [weak self] bytes in
                        self?.bondedClient?.onInboundBytes(bytes)
                    })
                log.info("relay socket pool configured endpoint=\(endpoint.raw, privacy: .public)")
            }
        }
        if bondedClient == nil {
            // First time the flag's been on this session. Pick a random
            // u64 session id; Phase 8 server lookup will use this to route.
            let sid = UInt64.random(in: UInt64.min...UInt64.max)
            let cfg = BondedClientConfig(sessionId: sid, mode: mode)
            let client = BondedClient(
                config: cfg,
                sendOnLink: { [weak self] linkId, bytes in
                    guard let self else { return }
                    if let pool = self.bondedSocketPool {
                        pool.send(linkId: linkId, bytes: bytes)
                    } else {
                        self.log.debug(
                            "bonded send \(bytes.count, privacy: .public)B on link=\(linkId, privacy: .public)")
                    }
                },
                queue: queue)
            client.reassembler.onOutbound = { [weak self] packet in
                self?.writeInboundPacketToFlow(packet)
            }
            client.updateLinks(states)
            client.start()
            bondedClient = client
            log.info("bonded transport enabled — mode=\(mode.rawValue, privacy: .public) \(states.count) links registered (session=\(String(format: "%016llx", sid), privacy: .public))")
        } else {
            bondedClient?.updateLinks(states)
            // Pick up runtime mode changes from policy updates without
            // recreating the client (preserves seq counter + retransmit
            // cache for in-flight streams).
            bondedClient?.setMode(mode)
        }
        bondedSocketPool?.updateLinks(linkInterfacesForEligibleLinks())
    }

    /// Translate the policy's bonding-mode string into the bonded layer
    /// enum. Unknown values silently default to `.speed` so a typo in
    /// `policy.json` doesn't disable the tunnel.
    private func bondedMode(_ raw: String) -> BondedBondingMode {
        return BondedBondingMode(rawValue: raw) ?? .speed
    }

    /// Translate the engine's link priority into the bonded scheduler's
    /// enum. Both enums share the same four cases — the switch is a static
    /// fan-out so changes to either side surface as a compile error.
    private func bondedPriority(_ p: LinkPriority) -> BondedLinkPriority {
        switch p {
        case .primary: return .primary
        case .secondary: return .secondary
        case .backup: return .backup
        case .never: return .never
        }
    }

    /// Idle sweep — every 5 s drop flows we haven't seen in 30 s.
    /// 30 s is the conservative side of typical TCP timeouts; UDP flows
    /// without follow-up traffic just disappear from the UI which is fine.
    private func scheduleSweep() {
        sweepTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.tracker.sweep(idleTimeout: 30)
        }
        t.resume()
        sweepTimer = t
    }

    /// Watch the OS' network paths so we always know which `NWInterface`
    /// corresponds to each BSD device name. The path monitor only fires
    /// when something changes, so steady-state cost is zero. We use this
    /// in [rebuildLinkInterfaces] to map link IDs (which carry BSD names)
    /// onto the `NWInterface` instances the forwarder needs.
    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.queue.async {
                var next: [String: NWInterface] = [:]
                for iface in path.availableInterfaces {
                    next[iface.name] = iface
                }
                self.bsdToInterface = next
                self.rebuildLinkInterfaces()
            }
        }
        pathMonitor.start(queue: queue)
    }

    /// Rebuild the forwarder's `linkId → NWInterface` map from the
    /// current policy + path snapshot. Called on every policy change
    /// and every path update. Cheap: just a dictionary build.
    private func rebuildLinkInterfaces() {
        let ifaces = linkInterfacesForEligibleLinks()
        var bsds: [String: String] = [:]
        for slot in decision.eligible {
            guard let bsd = slot.link.interfaceName, !bsd.isEmpty else { continue }
            bsds[slot.link.id] = bsd
        }
        forwarder.setLinkInterfaces(ifaces, bsdMap: bsds)
        bondedSocketPool?.updateLinks(ifaces)
    }

    private func linkInterfacesForEligibleLinks() -> [String: NWInterface] {
        var ifaces: [String: NWInterface] = [:]
        for slot in decision.eligible {
            guard let bsd = slot.link.interfaceName, !bsd.isEmpty else { continue }
            if let iface = bsdToInterface[bsd] {
                ifaces[slot.link.id] = iface
            }
        }
        return ifaces
    }

    private func writeInboundPacketToFlow(_ packet: Data) {
        guard !packet.isEmpty else { return }
        let version = packet.first! >> 4
        let proto: NSNumber
        switch version {
        case 4:
            proto = NSNumber(value: AF_INET)
        case 6:
            proto = NSNumber(value: AF_INET6)
        default:
            log.debug("dropping relay packet with unknown IP version=\(version, privacy: .public)")
            return
        }
        packetFlow.writePackets([packet], withProtocols: [proto])
    }

    /// Snapshot of per-link bytes since the previous call. Drains the
    /// forwarder accumulators and returns a serializable list the
    /// container app fetches via `getThroughput` RPC. The container
    /// turns the bytes-per-second deltas into `LinkMetric` events that
    /// drive the UI's bond-graphic particle flow and bandwidth chips.
    func drainThroughputForRPC() -> [[String: Any]] {
        var out: [[String: Any]] = []
        let snap = forwarder.drainThroughput()
        for (linkId, bytes) in snap {
            out.append([
                "linkId": linkId,
                "bytesIn": bytes.inBytes,
                "bytesOut": bytes.outBytes,
            ])
        }
        return out
    }
}
