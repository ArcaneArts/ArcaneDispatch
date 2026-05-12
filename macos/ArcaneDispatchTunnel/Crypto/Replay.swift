// Swift mirror of the sliding-window anti-replay tracker.
//
// See `speed-server/crypto/replay.go` and `lib/crypto/replay.dart` for
// the canonical prose. Window semantics:
//
//   * Tracks the highest nonce seen so far.
//   * Anything more than `windowSize` below the high-watermark is
//     rejected as "too old".
//   * Anything inside the window is tracked via a bitmap; duplicates are
//     rejected.
//   * Anything above the high-watermark is accepted and shifts the
//     window forward.
//
// `windowSize` defaults to 1024 (matches Go/Dart), which gives ~16 µs of
// 8-Gbps overlap protection at a 1500-byte MTU. The bitmap is a single
// `UInt64` array of length 16.

import Foundation

public final class ReplayWindow {
    public let windowSize: UInt64
    private var highWater: UInt64 = 0
    private var hasAny: Bool = false
    private var bitmap: [UInt64]

    public init(windowSize: UInt64 = 1024) {
        precondition(windowSize > 0, "windowSize must be positive")
        precondition(windowSize % 64 == 0, "windowSize must be multiple of 64")
        self.windowSize = windowSize
        self.bitmap = Array(repeating: 0, count: Int(windowSize / 64))
    }

    /// Try to accept a frame at `nonce`. Returns `true` if it's new and
    /// in-window; `false` if it's a duplicate or too far below the
    /// high-watermark.
    @discardableResult
    public func accept(_ nonce: UInt64) -> Bool {
        if !hasAny {
            highWater = nonce
            hasAny = true
            setBit(0)
            return true
        }
        if nonce > highWater {
            let shift = nonce - highWater
            shiftLeft(by: shift)
            highWater = nonce
            setBit(0)
            return true
        }
        let offset = highWater - nonce
        if offset >= windowSize {
            return false // too old
        }
        if isSet(Int(offset)) {
            return false // duplicate
        }
        setBit(Int(offset))
        return true
    }

    /// Diagnostic — high-water nonce (or 0 if nothing accepted yet).
    public var highestNonce: UInt64 { hasAny ? highWater : 0 }

    // ----- Internals -----

    private func setBit(_ offset: Int) {
        let word = offset / 64
        let bit = offset % 64
        bitmap[word] |= 1 << bit
    }

    private func isSet(_ offset: Int) -> Bool {
        let word = offset / 64
        let bit = offset % 64
        return (bitmap[word] & (1 << bit)) != 0
    }

    private func shiftLeft(by amount: UInt64) {
        if amount >= windowSize {
            for i in 0..<bitmap.count { bitmap[i] = 0 }
            return
        }
        let n = Int(amount)
        let wordShift = n / 64
        let bitShift = n % 64
        var result = Array(repeating: UInt64(0), count: bitmap.count)
        for i in 0..<bitmap.count {
            let dst = i + wordShift
            if dst >= bitmap.count { continue }
            result[dst] |= bitmap[i] << bitShift
            if bitShift != 0, dst + 1 < bitmap.count {
                result[dst + 1] |= bitmap[i] >> UInt64(64 - bitShift)
            }
        }
        bitmap = result
    }
}
