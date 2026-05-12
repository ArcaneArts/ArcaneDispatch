// Sliding-window reassembler for the bonded transport.
//
// Mirror of `lib/bonded/bonded_reassembler.dart`. See module header in the
// Dart source for the algorithm and rationale; this file just ports the
// behaviour into Swift idioms. The single-threaded model is enforced by
// running the caller on a serial DispatchQueue (`BondedClient.queue`).
//
// Emit contract (must match the Dart side exactly):
//   * `onPayload(seq:payload:)` either delivers immediately, buffers
//     in-order with hole, or drops as duplicate/stale.
//   * `onOutbound` callback fires for every delivered payload in seq order.
//   * `onNakRange` callback fires when a hole stays open past `gapTimeout`.

import Foundation

/// Inclusive seq range the receiver hasn't seen yet.
public struct BondedNakRange {
    public let startSeq: UInt64
    public let endSeq: UInt64
    public init(_ startSeq: UInt64, _ endSeq: UInt64) {
        self.startSeq = startSeq
        self.endSeq = endSeq
    }
    public var length: UInt64 { endSeq - startSeq + 1 }
}

/// Read-only stats snapshot.
public struct BondedReassemblerStats {
    public let nextExpectedSeq: UInt64
    public let delivered: Int
    public let droppedStale: Int
    public let droppedDuplicate: Int
    public let naks: Int
    public let bufferedBytes: Int
    public let bufferedCount: Int
}

public final class BondedReassembler {
    public typealias OutboundCallback = (Data) -> Void
    public typealias NakCallback = (BondedNakRange) -> Void

    private var nextSeq: UInt64
    private var buffer: [UInt64: Data] = [:]
    private var gapSince: Date?
    private var gapTimer: DispatchSourceTimer?

    public let windowSize: Int
    public var gapTimeout: DispatchTimeInterval
    public let maxBufferedBytes: Int
    public let queue: DispatchQueue

    private var deliveredCount: Int = 0
    private var droppedStale: Int = 0
    private var droppedDuplicate: Int = 0
    private var naks: Int = 0
    private var isDisposed: Bool = false

    /// Invoked in-order with delivered payloads. Caller is expected to
    /// fan-out to the tunnel write path.
    public var onOutbound: OutboundCallback?

    /// Invoked when a gap exceeds `gapTimeout`. The `BondedClient` turns
    /// these into NAK frames and ships them on the best healthy link.
    public var onNakRange: NakCallback?

    public init(
        initialNextSeq: UInt64 = 0,
        windowSize: Int = 4096,
        gapTimeout: DispatchTimeInterval = .milliseconds(100),
        maxBufferedBytes: Int = 4 * 1024 * 1024,
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) {
        precondition(windowSize > 0)
        precondition(maxBufferedBytes > 0)
        self.nextSeq = initialNextSeq
        self.windowSize = windowSize
        self.gapTimeout = gapTimeout
        self.maxBufferedBytes = maxBufferedBytes
        self.queue = queue
    }

    public func snapshot() -> BondedReassemblerStats {
        var bufferedBytes = 0
        for v in buffer.values { bufferedBytes += v.count }
        return BondedReassemblerStats(
            nextExpectedSeq: nextSeq,
            delivered: deliveredCount,
            droppedStale: droppedStale,
            droppedDuplicate: droppedDuplicate,
            naks: naks,
            bufferedBytes: bufferedBytes,
            bufferedCount: buffer.count
        )
    }

    /// Feed a freshly-decoded payload into the reassembler.
    public func onPayload(seq: UInt64, payload: Data) {
        if isDisposed { return }
        if seq < nextSeq {
            droppedDuplicate += 1
            return
        }
        if seq >= nextSeq + UInt64(windowSize) {
            droppedStale += 1
            return
        }
        if seq == nextSeq {
            emit(seq: seq, payload: payload)
            drainBuffer()
            updateGapState()
            return
        }
        if buffer[seq] != nil {
            droppedDuplicate += 1
            return
        }
        if bufferedBytes() + payload.count > maxBufferedBytes {
            evictHighest()
        }
        buffer[seq] = payload
        updateGapState()
    }

    /// Tear down. Idempotent.
    public func dispose() {
        if isDisposed { return }
        isDisposed = true
        gapTimer?.cancel()
        gapTimer = nil
        buffer.removeAll()
    }

    // MARK: - internals

    private func emit(seq: UInt64, payload: Data) {
        onOutbound?(payload)
        nextSeq = seq + 1
        deliveredCount += 1
    }

    private func drainBuffer() {
        while let payload = buffer.removeValue(forKey: nextSeq) {
            emit(seq: nextSeq, payload: payload)
        }
    }

    private func updateGapState() {
        let hasGap = !buffer.isEmpty
        if !hasGap {
            gapSince = nil
            gapTimer?.cancel()
            gapTimer = nil
            return
        }
        if gapSince == nil { gapSince = Date() }
        if gapTimer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + gapTimeout)
            t.setEventHandler { [weak self] in self?.onGapTimeout() }
            t.resume()
            gapTimer = t
        }
    }

    private func onGapTimeout() {
        gapTimer = nil
        if isDisposed { return }
        if buffer.isEmpty {
            gapSince = nil
            return
        }
        var lowestBuffered: UInt64 = .max
        for k in buffer.keys {
            if k < lowestBuffered { lowestBuffered = k }
        }
        // gapEnd is strictly lower than lowestBuffered. lowestBuffered is
        // guaranteed > nextSeq because we only buffer seqs > nextSeq.
        let gapEnd = lowestBuffered - 1
        let range = BondedNakRange(nextSeq, gapEnd)
        naks += 1
        onNakRange?(range)

        gapSince = Date()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + gapTimeout)
        t.setEventHandler { [weak self] in self?.onGapTimeout() }
        t.resume()
        gapTimer = t
    }

    private func bufferedBytes() -> Int {
        var n = 0
        for v in buffer.values { n += v.count }
        return n
    }

    private func evictHighest() {
        if buffer.isEmpty { return }
        var highest: UInt64 = nextSeq
        for k in buffer.keys {
            if k > highest { highest = k }
        }
        buffer.removeValue(forKey: highest)
        droppedStale += 1
    }
}
