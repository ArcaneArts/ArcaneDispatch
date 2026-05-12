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
// * Publish flow events (`created`/`bytes`/`closed`) to the shared ring
//   buffer via `FlowStatsPublisher` so the Dart side's flow inspector can
//   render live activity without round-tripping through a method channel.
// * Honor kill-switch semantics: when the engine reports no eligible links
//   and `killSwitch` is on, every outbound packet is dropped.
//
// Phase 7 will replace the per-flow socket bridge with the bonded transport;
// for now we still drop the packet on the floor after picking the link, so
// the tunnel doesn't actually relay traffic. The UI bookkeeping is fully
// functional, though, and matches what Phase 7 will produce.

import Foundation
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
    private let publisher = FlowStatsPublisher()
    private var tracker: FlowTracker!
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

    init(packetFlow: NEPacketTunnelFlow, policy: ExtensionPolicy) {
        self.packetFlow = packetFlow
        self.policy = policy
        self.tracker = FlowTracker { [weak self] event in
            self?.publisher.publish(event)
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.running { return }
            self.running = true
            self.publisher.openIfNeeded()
            self.decision = self.engine.evaluate(policy: self.policy, metrics: self.metrics)
            self.rebuildBondedClientIfNeeded()
            self.scheduleSweep()
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
            self.bondedClient?.dispose()
            self.bondedClient = nil
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
            // Observe — this both classifies and bookkeeps the flow.
            _ = tracker.observe(packet: packet, direction: .outbound) { [weak self] _ in
                return self?.assignLink() ?? ""
            }
            // Phase 7: when the debug flag is on, mirror the packet through
            // the bonded encoder so we can `OSLog`-inspect frames on real
            // hardware. There's no server yet (Phase 8) — the encoded bytes
            // are dropped after logging. The legacy per-flow forwarder
            // remains in charge of actual delivery.
            if let client = bondedClient {
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
    /// Phase 7 wiring deliberately keeps the `sendOnLink` callback as a
    /// log-only stub. Phase 8 will replace it with a real `BondedSocketPool`
    /// that opens UDP sockets bound to each link's source address.
    private func rebuildBondedClientIfNeeded() {
        let wantBonded = policy.bondedTransport ?? false
        if !wantBonded {
            if let existing = bondedClient {
                existing.dispose()
                bondedClient = nil
                bondedWireIds.removeAll()
                log.info("bonded transport disabled — encoder torn down")
            }
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
        if bondedClient == nil {
            // First time the flag's been on this session. Pick a random
            // u64 session id; Phase 8 server lookup will use this to route.
            let sid = UInt64.random(in: UInt64.min...UInt64.max)
            let cfg = BondedClientConfig(sessionId: sid, mode: mode)
            let client = BondedClient(
                config: cfg,
                sendOnLink: { [weak self] linkId, bytes in
                    self?.log.debug(
                        "bonded send \(bytes.count, privacy: .public)B on link=\(linkId, privacy: .public)")
                },
                queue: queue)
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
}
