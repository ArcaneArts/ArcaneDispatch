// Bonded session orchestrator (Swift side).
//
// Mirrors `lib/bonded/bonded_session.dart`. Lives inside the system
// extension and is wired into the `PacketPump` write loop when
// `bondedTransport=true` in `policy.json`.
//
// Per-link sockets are abstracted behind `BondedSendOnLink`: the caller
// owns the UDP send/recv loops and just forwards bytes here. This keeps
// BondedClient pure-logic and trivially unit-testable, matching the Dart
// session's testing story.

import Foundation

/// Callback fired when the orchestrator has a fully-encoded frame ready
/// to put on a specific link. `BondedSocketPool` is responsible for the
/// actual relay send.
public typealias BondedSendOnLink = (_ linkId: String, _ bytes: Data) -> Void

public typealias BondedDecisionObserver = (BondedSchedulingDecision) -> Void

/// Optional transform applied to every outbound frame *after* framing
/// but *before* `sendOnLink`. Canonical use is `Crypto.seal(transport, frame)`.
public typealias BondedFrameSealer = (Data) -> Data

/// Optional transform applied to every inbound wire blob *before* framing
/// is decoded. Return `nil` to drop the bytes silently (e.g. AEAD failure).
public typealias BondedFrameOpener = (Data) -> Data?

public struct BondedClientConfig {
    public let sessionId: UInt64
    public let keepaliveInterval: DispatchTimeInterval
    public let reassemblerGapTimeout: DispatchTimeInterval
    public let reassemblerWindowSize: Int
    public let maxPayload: Int
    public let retransmitBufferSize: Int
    /// Initial bonding mode. Mutable at runtime via [BondedClient.setMode].
    public let mode: BondedBondingMode

    public init(
        sessionId: UInt64,
        keepaliveInterval: DispatchTimeInterval = .milliseconds(200),
        reassemblerGapTimeout: DispatchTimeInterval = .milliseconds(100),
        reassemblerWindowSize: Int = 4096,
        maxPayload: Int = kBondedMaxPayload,
        retransmitBufferSize: Int = 256,
        mode: BondedBondingMode = .speed
    ) {
        self.sessionId = sessionId
        self.keepaliveInterval = keepaliveInterval
        self.reassemblerGapTimeout = reassemblerGapTimeout
        self.reassemblerWindowSize = reassemblerWindowSize
        self.maxPayload = maxPayload
        self.retransmitBufferSize = retransmitBufferSize
        self.mode = mode
    }
}

public struct BondedClientStats {
    public let lastSentSeq: UInt64
    public let inbound: BondedReassemblerStats
    public let packetsPerLink: [String: Int]
    public let bytesPerLink: [String: Int]
    public let retransmissions: Int
    public let keepalives: Int
    /// Number of chunks where the active mode fanned out the same seq
    /// to multiple links.
    public let duplicateFanouts: Int
    /// Active bonding mode at snapshot time.
    public let mode: BondedBondingMode
}

private struct RetransmitEntry {
    let originalLinkId: String
    let payload: Data
}

public final class BondedClient {
    public let config: BondedClientConfig
    public let scheduler: BondedScheduler
    public let reassembler: BondedReassembler
    public let queue: DispatchQueue

    private let sendOnLink: BondedSendOnLink
    private let observer: BondedDecisionObserver?
    private let sealer: BondedFrameSealer?
    private let opener: BondedFrameOpener?

    private var nextSeq: UInt64 = 0
    /// LRU-ish retransmit cache keyed by seq. We use an ordered dictionary
    /// pattern via `seqOrder` + `cache` so trimming the oldest entry is
    /// O(1) and doesn't require a SortedSet.
    private var cache: [UInt64: RetransmitEntry] = [:]
    private var seqOrder: [UInt64] = []
    private var keepaliveTimers: [String: DispatchSourceTimer] = [:]
    private var packetsPerLink: [String: Int] = [:]
    private var bytesPerLink: [String: Int] = [:]
    private var retransmissions: Int = 0
    private var keepalives: Int = 0
    private var duplicateFanouts: Int = 0
    private var strategy: BondedModeStrategy

    private var started: Bool = false
    private var disposed: Bool = false

    public init(
        config: BondedClientConfig,
        sendOnLink: @escaping BondedSendOnLink,
        scheduler: BondedScheduler? = nil,
        reassembler: BondedReassembler? = nil,
        observer: BondedDecisionObserver? = nil,
        sealer: BondedFrameSealer? = nil,
        opener: BondedFrameOpener? = nil,
        queue: DispatchQueue = DispatchQueue(label: "ArcaneDispatch.bonded-client")
    ) {
        self.config = config
        self.sendOnLink = sendOnLink
        self.observer = observer
        self.sealer = sealer
        self.opener = opener
        self.queue = queue
        self.scheduler = scheduler ?? BondedScheduler()
        self.reassembler = reassembler ?? BondedReassembler(
            windowSize: config.reassemblerWindowSize,
            gapTimeout: config.reassemblerGapTimeout,
            queue: queue
        )
        self.strategy = BondedModes.strategy(for: config.mode)
        // Wire reassembler's gap detector to NAK encoding (NOT to local
        // retransmit handling — only the original sender has the bytes).
        self.reassembler.onNakRange = { [weak self] r in
            self?.sendNakToPeer(range: r)
        }
    }

    /// Currently-active bonding mode.
    public var mode: BondedBondingMode {
        var current: BondedBondingMode = .speed
        queue.sync { current = self.strategy.mode }
        return current
    }

    /// Switch the bonding mode at runtime. Cheap — the existing
    /// scheduler, reassembler, retransmit cache, and seq counter all
    /// carry over so in-flight TCP streams are not disturbed.
    public func setMode(_ mode: BondedBondingMode) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.strategy.mode == mode { return }
            self.strategy = BondedModes.strategy(for: mode)
        }
    }

    /// Spin up keepalive timers + start internal subscriptions. Idempotent.
    public func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.started || self.disposed { return }
            self.started = true
            self.restartKeepalives()
        }
    }

    /// Push policy/metrics into the scheduler; reset keepalives to match.
    public func updateLinks(_ links: [BondedLinkState]) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.scheduler.updateLinks(links)
            if self.started { self.restartKeepalives() }
        }
    }

    /// Send application bytes through the bond. Splits into ≤ maxPayload
    /// chunks. Returns the number of bytes scheduled — could be less than
    /// the input when no link is eligible.
    @discardableResult
    public func send(_ bytes: Data) -> Int {
        if disposed || !started || bytes.isEmpty { return 0 }
        var scheduled = 0
        queue.sync {
            var offset = 0
            while offset < bytes.count {
                var chunkLen = bytes.count - offset
                if chunkLen > config.maxPayload { chunkLen = config.maxPayload }
                let chunk = bytes.subdata(in: (bytes.startIndex + offset)..<(bytes.startIndex + offset + chunkLen))
                if !self.sendOne(chunk: chunk) { break }
                offset += chunkLen
                scheduled += chunkLen
            }
        }
        return scheduled
    }

    /// Hand an inbound frame to the orchestrator. Routes to keepalive /
    /// NAK / ACK handlers or to the reassembler depending on flags.
    public func onInboundFrame(_ frame: BondedFrame) {
        queue.async { [weak self] in
            guard let self = self, !self.disposed else { return }
            if frame.sessionId != self.config.sessionId { return }
            if frame.isKeepalive { return }
            if frame.isAck {
                self.scheduler.completeSend(
                    linkId: self.linkIdForWire(frame.linkId),
                    bytes: frame.payload.count)
                return
            }
            if frame.isNak {
                self.handlePeerNak(payload: frame.payload)
                return
            }
            self.reassembler.onPayload(seq: frame.seq, payload: frame.payload)
        }
    }

    /// Hand a fresh blob of wire bytes from a link to the orchestrator.
    /// Unseals (if [opener] is wired), decodes the bonded frame, then
    /// dispatches via `onInboundFrame`. Returns `true` if accepted,
    /// `false` if dropped (unseal failure, malformed framing).
    @discardableResult
    public func onInboundBytes(_ wireBytes: Data) -> Bool {
        if disposed { return false }
        guard let plain = openIfEnabled(wireBytes) else { return false }
        do {
            let frame = try decodeBondedFrame(plain)
            onInboundFrame(frame)
            return true
        } catch {
            return false
        }
    }

    /// Snapshot for the UI / telemetry tick.
    public func snapshot() -> BondedClientStats {
        var stats: BondedClientStats!
        queue.sync {
            stats = BondedClientStats(
                lastSentSeq: nextSeq == 0 ? 0 : nextSeq - 1,
                inbound: self.reassembler.snapshot(),
                packetsPerLink: self.packetsPerLink,
                bytesPerLink: self.bytesPerLink,
                retransmissions: self.retransmissions,
                keepalives: self.keepalives,
                duplicateFanouts: self.duplicateFanouts,
                mode: self.strategy.mode
            )
        }
        return stats
    }

    /// Tear down. Idempotent.
    public func dispose() {
        queue.sync {
            if disposed { return }
            disposed = true
            for t in keepaliveTimers.values { t.cancel() }
            keepaliveTimers.removeAll()
            reassembler.dispose()
        }
    }

    // MARK: - internals (all run on `queue`)

    private func sendOne(chunk: Data) -> Bool {
        let plan = strategy.planChunk(bytes: chunk.count, scheduler: scheduler)
        if plan.isEmpty { return false }
        // All copies in this fan-out share the same seq so the
        // receiver dedupes naturally via the reassembler.
        let seq = nextSeq
        nextSeq &+= 1
        let first = plan.sends[0]
        // The retransmit cache stores the *primary* link choice; if the
        // peer NAKs we'll reroute via a fresh scheduler.pickLink anyway.
        cache[seq] = RetransmitEntry(originalLinkId: first.linkId, payload: chunk)
        seqOrder.append(seq)
        trimRetransmitCache()

        do {
            for d in plan.sends {
                let frame = try encodeBondedFrame(
                    sessionId: config.sessionId,
                    seq: seq,
                    linkId: d.wireId,
                    payload: chunk)
                sendOnLink(d.linkId, sealIfEnabled(frame))
                packetsPerLink[d.linkId, default: 0] += 1
                bytesPerLink[d.linkId, default: 0] += chunk.count
                observer?(d)
            }
            if plan.fanout > 1 {
                duplicateFanouts += 1
            }
            return true
        } catch {
            // Encoding failure means we have a bug; just drop and return
            // true so the caller's loop doesn't spin on the same chunk.
            return true
        }
    }

    private func trimRetransmitCache() {
        while seqOrder.count > config.retransmitBufferSize {
            let oldest = seqOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    private func sendNakToPeer(range: BondedNakRange) {
        if disposed { return }
        guard let best = bestHealthyLinkForControl() else { return }
        var payload = Data(count: 16)
        payload.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let ptr = raw.baseAddress!
            ptr.storeBytes(of: range.startSeq.bigEndian, as: UInt64.self)
            ptr.advanced(by: 8).storeBytes(of: range.endSeq.bigEndian, as: UInt64.self)
        }
        do {
            let frame = try encodeBondedFrame(
                sessionId: config.sessionId,
                seq: 0,
                linkId: best.wireId,
                flags: BondedFlags.nak,
                payload: payload)
            sendOnLink(best.linkId, sealIfEnabled(frame))
        } catch {
            // Couldn't encode our own NAK — really only happens on a
            // logic bug. Swallow rather than crash the tunnel.
            return
        }
    }

    /// Lowest-RTT link in the best-priority bucket. Used for control
    /// frames so we don't pollute scheduler credit with 40-byte NAKs.
    private func bestHealthyLinkForControl() -> BondedLinkState? {
        var winner: BondedLinkState? = nil
        var bestRtt = Double.infinity
        var bestBucket: BondedLinkPriority? = nil
        for s in scheduler.states.values {
            if s.status == .unhealthy || s.status == .disabled { continue }
            if s.priority == .never { continue }
            if bestBucket == nil
                || priorityRank(s.priority) < priorityRank(bestBucket!) {
                winner = s
                bestBucket = s.priority
                bestRtt = s.rttMs
            } else if s.priority == bestBucket && s.rttMs < bestRtt {
                winner = s
                bestRtt = s.rttMs
            }
        }
        return winner
    }

    private func priorityRank(_ p: BondedLinkPriority) -> Int {
        switch p {
        case .primary: return 0
        case .secondary: return 1
        case .backup: return 2
        case .never: return 3
        }
    }

    private func retransmitRange(_ range: BondedNakRange) {
        if disposed { return }
        var seq = range.startSeq
        while seq <= range.endSeq {
            defer { seq &+= 1 }
            guard let entry = cache[seq] else { continue }
            guard let d = scheduler.pickLink(bytes: entry.payload.count) else {
                // No healthy link; bail out, the peer will NAK again.
                return
            }
            do {
                let frame = try encodeBondedFrame(
                    sessionId: config.sessionId,
                    seq: seq,
                    linkId: d.wireId,
                    flags: BondedFlags.retransmit,
                    payload: entry.payload)
                sendOnLink(d.linkId, sealIfEnabled(frame))
                retransmissions += 1
                observer?(d)
            } catch {
                // Encode bug; same handling as `sendOne`.
            }
        }
    }

    private func handlePeerNak(payload: Data) {
        if payload.count < 16 { return }
        let startSeq = payload.readUInt64BE(at: 0)
        let endSeq = payload.readUInt64BE(at: 8)
        if endSeq < startSeq { return }
        retransmitRange(BondedNakRange(startSeq, endSeq))
    }

    private func restartKeepalives() {
        for t in keepaliveTimers.values { t.cancel() }
        keepaliveTimers.removeAll()
        if disposed { return }
        for s in scheduler.states.values {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + config.keepaliveInterval,
                repeating: config.keepaliveInterval)
            let linkId = s.linkId
            let wireId = s.wireId
            timer.setEventHandler { [weak self] in
                self?.sendKeepalive(linkId: linkId, wireId: wireId)
            }
            timer.resume()
            keepaliveTimers[s.linkId] = timer
        }
    }

    private func sendKeepalive(linkId: String, wireId: UInt16) {
        if disposed { return }
        let inflight = UInt64(scheduler.inflightForTest(linkId: linkId))
        var body = Data(count: 8)
        body.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            raw.baseAddress!.storeBytes(of: inflight.littleEndian, as: UInt64.self)
        }
        do {
            let frame = try encodeBondedFrame(
                sessionId: config.sessionId,
                seq: 0,
                linkId: wireId,
                flags: BondedFlags.keepalive,
                payload: body)
            sendOnLink(linkId, sealIfEnabled(frame))
            keepalives += 1
        } catch {
            // Same as above.
        }
    }

    private func linkIdForWire(_ wireId: UInt16) -> String {
        for s in scheduler.states.values where s.wireId == wireId {
            return s.linkId
        }
        return ""
    }

    /// Optional seal pass. Returns the frame untouched when no sealer is
    /// wired (the common case during early bring-up).
    private func sealIfEnabled(_ frame: Data) -> Data {
        guard let s = sealer else { return frame }
        return s(frame)
    }

    /// Optional unseal pass. Returns `nil` when the opener rejects the
    /// bytes; callers drop silently in that case.
    private func openIfEnabled(_ wireBytes: Data) -> Data? {
        guard let o = opener else { return wireBytes }
        return o(wireBytes)
    }
}
