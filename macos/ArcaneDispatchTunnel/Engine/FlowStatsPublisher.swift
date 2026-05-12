// FlowStatsPublisher.swift
//
// Writes `FlowEvent`s into a shared, mmap-backed ring buffer in the App Group
// container so the Dart side's flow inspector can render live activity without
// having to round-trip every event through a method channel.
//
// Format (all little-endian, fixed-size records, no compression):
//
//   ┌──────────── header (32 B) ────────────┐
//   │ magic     4   "ADFS"                  │
//   │ version   2   u16   (1)               │
//   │ recordSz  2   u16   (256)             │
//   │ capacity  4   u32   (ring slots)      │
//   │ reserved  4                           │
//   │ writeIx   8   u64   monotonic         │
//   │ reserved  8                           │
//   └───────────────────────────────────────┘
//   ┌──────────── slot 0 (256 B) ───────────┐
//   ...
//   ┌──────────── slot N-1 (256 B) ─────────┐
//
// Record layout (256 bytes, see byte offsets in `writeRecord` below):
//   timestamp(f64) kind(u8) family(u8) proto(u8) linkIdLen(u8)
//   flowId(u64) localPort(u16) remotePort(u16) bytesOut(u64) bytesIn(u64)
//   linkId[48] localAddrLen(u8) localAddress[79] remoteAddrLen(u8)
//   remoteAddress[79] isRealtime(u8) padding[7]
//
// Race model: single producer (the extension), many readers (Dart polls every
// ~250 ms). Readers use `writeIx` to know how far the writer has gotten and
// decide which slots are fresh. We don't claim wait-free semantics; on the
// rare case where a reader catches a half-written slot it'll see a sentinel
// timestamp (NaN) and skip the row.

import Foundation
import OSLog

/// Drives the flow_stats.bin ring buffer in the App Group container.
/// One instance per extension process; consumed by `FlowTracker.onEvent`.
final class FlowStatsPublisher {
    private let log = Logger(subsystem: "art.arcane.dispatch.tunnel", category: "flowstats")
    private let appGroupId: String
    private let fileName: String

    /// Per-record byte count. Lock-step with the Dart reader; don't change
    /// without bumping `formatVersion` and the reader at the same time.
    static let recordSize = 256
    static let headerSize = 32
    static let formatVersion: UInt16 = 2
    /// Magic bytes "ADFS" (Arcane Dispatch Flow Stats).
    static let magic: [UInt8] = [0x41, 0x44, 0x46, 0x53]

    /// Number of slots in the ring. 4096 × 256 B = 1 MiB. 4 k events at 60 Hz
    /// gives the Dart reader ~70 s of slack if it sleeps long; plenty for an
    /// always-on UI but small enough to be a non-issue on memory.
    let capacity: UInt32

    private var fileHandle: FileHandle?
    private var fileURL: URL?
    /// Sticky flag set to true on the first `openIfNeeded` attempt that
    /// failed (e.g. the App Group container is unavailable because the
    /// entitlement was stripped). We never retry once flipped — retrying
    /// from `publish()` was the cause of the `dispatch_sync called on
    /// queue already owned by current thread` crash because `publish()`
    /// runs `openIfNeeded()` from inside the same serial queue.
    private var openAttempted: Bool = false
    /// Monotonic write counter. Slot for a given event is `writeIndex % capacity`.
    private var writeIndex: UInt64 = 0
    private let queue = DispatchQueue(label: "art.arcane.dispatch.tunnel.flowstats", qos: .utility)

    init(
        appGroupId: String = "group.art.arcane.dispatch",
        fileName: String = "flow_stats.bin",
        capacity: UInt32 = 4096
    ) {
        self.appGroupId = appGroupId
        self.fileName = fileName
        self.capacity = capacity
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Lazy-open the ring buffer and write its header if the file is new or
    /// the version stamp doesn't match. Safe to call from anywhere; takes
    /// the internal queue. Callers that already hold the queue must use
    /// `openIfNeededLocked()` directly to avoid `dispatch_sync` on the
    /// queue that owns the current thread.
    func openIfNeeded() {
        queue.sync { self.openIfNeededLocked() }
    }

    /// Same as `openIfNeeded()` but assumes the caller is already executing
    /// on `queue`. After the first attempt — successful or not — this is a
    /// no-op for the lifetime of the publisher; we never retry, so a missing
    /// App Group entitlement is a one-shot failure instead of a hot loop.
    private func openIfNeededLocked() {
        if fileHandle != nil { return }
        if openAttempted { return }
        openAttempted = true
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else {
            log.error("flow_stats: App Group container missing for \(self.appGroupId); flow stats disabled")
            return
        }
        let url = container.appendingPathComponent(fileName)
        let totalSize = FlowStatsPublisher.headerSize + Int(capacity) * FlowStatsPublisher.recordSize

        let needsInit = !FileManager.default.fileExists(atPath: url.path)
        if needsInit {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forUpdating: url) else {
            log.error("flow_stats: failed to open \(url.path) for writing")
            return
        }
        // Pre-allocate to full size so reader mmap doesn't trip over a
        // short file.
        do {
            try handle.truncate(atOffset: UInt64(totalSize))
        } catch {
            log.error("flow_stats: truncate failed: \(error.localizedDescription)")
        }
        fileHandle = handle
        fileURL = url
        if needsInit {
            writeHeader()
        } else {
            // Existing file — read writeIndex back so subsequent records
            // append after the last write. If the header is stale or
            // wrong-version we reset cold.
            if !validateHeader() {
                log.notice("flow_stats: stale header, reinitializing")
                writeHeader()
                writeIndex = 0
            } else {
                writeIndex = readWriteIndex()
            }
        }
        log.info("flow_stats: opened \(url.path) (capacity=\(self.capacity), writeIndex=\(self.writeIndex))")
    }

    /// Append one event to the ring buffer. Fire-and-forget; the queue
    /// serializes writes so the producer never blocks on I/O.
    func publish(_ event: FlowEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.fileHandle == nil {
                // We're already on `queue` — call the locked variant to
                // avoid the recursive `dispatch_sync` that used to crash the
                // tunnel extension whenever the App Group container was
                // missing (no entitlement → openIfNeededLocked() bails fast
                // but used to be retried on every publish).
                self.openIfNeededLocked()
            }
            guard self.fileHandle != nil else { return }
            self.writeRecord(event: event)
        }
    }

    // MARK: - Private --------------------------------------------------------

    private func writeHeader() {
        guard let handle = fileHandle else { return }
        var bytes = [UInt8](repeating: 0, count: FlowStatsPublisher.headerSize)
        // magic
        bytes[0] = FlowStatsPublisher.magic[0]
        bytes[1] = FlowStatsPublisher.magic[1]
        bytes[2] = FlowStatsPublisher.magic[2]
        bytes[3] = FlowStatsPublisher.magic[3]
        // version (u16 LE)
        let ver = FlowStatsPublisher.formatVersion
        bytes[4] = UInt8(truncatingIfNeeded: ver)
        bytes[5] = UInt8(truncatingIfNeeded: ver >> 8)
        // recordSize (u16 LE)
        let rs = UInt16(FlowStatsPublisher.recordSize)
        bytes[6] = UInt8(truncatingIfNeeded: rs)
        bytes[7] = UInt8(truncatingIfNeeded: rs >> 8)
        // capacity (u32 LE)
        writeUInt32LE(value: capacity, into: &bytes, at: 8)
        // reserved 12..15
        // writeIndex (u64 LE)
        writeUInt64LE(value: 0, into: &bytes, at: 16)
        // reserved 24..31
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: bytes)
        } catch {
            log.error("flow_stats: header write failed: \(error.localizedDescription)")
        }
    }

    /// True if the on-disk header matches what we expect.
    private func validateHeader() -> Bool {
        guard let handle = fileHandle else { return false }
        do {
            try handle.seek(toOffset: 0)
            guard let hdr = try handle.read(upToCount: FlowStatsPublisher.headerSize),
                  hdr.count == FlowStatsPublisher.headerSize else { return false }
            if hdr[0] != FlowStatsPublisher.magic[0] || hdr[1] != FlowStatsPublisher.magic[1]
                || hdr[2] != FlowStatsPublisher.magic[2] || hdr[3] != FlowStatsPublisher.magic[3] {
                return false
            }
            let ver = UInt16(hdr[4]) | (UInt16(hdr[5]) << 8)
            return ver == FlowStatsPublisher.formatVersion
        } catch {
            return false
        }
    }

    private func readWriteIndex() -> UInt64 {
        guard let handle = fileHandle else { return 0 }
        do {
            try handle.seek(toOffset: 16)
            guard let bytes = try handle.read(upToCount: 8), bytes.count == 8 else { return 0 }
            return readUInt64LE(from: bytes, at: 0)
        } catch {
            return 0
        }
    }

    private func writeRecord(event: FlowEvent) {
        guard let handle = fileHandle else { return }
        var bytes = [UInt8](repeating: 0, count: FlowStatsPublisher.recordSize)

        // timestamp at 0..7 (Float64 LE)
        let ts = event.timestamp.bitPattern
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: ts >> (8 * i))
        }
        // kind at 8
        bytes[8] = event.kind.rawValue
        // family at 9
        bytes[9] = event.flow.key.family.rawValue
        // protocol at 10
        bytes[10] = event.flow.key.networkProtocol
        // linkIdLen at 11 (filled below)
        // flowId at 12..19
        writeUInt64LE(value: event.flow.id, into: &bytes, at: 12)
        // localPort at 20..21
        writeUInt16LE(value: event.flow.key.localPort, into: &bytes, at: 20)
        // remotePort at 22..23
        writeUInt16LE(value: event.flow.key.remotePort, into: &bytes, at: 22)
        // bytesOut at 24..31
        writeUInt64LE(value: event.flow.bytesOut, into: &bytes, at: 24)
        // bytesIn at 32..39
        writeUInt64LE(value: event.flow.bytesIn, into: &bytes, at: 32)
        // linkId at 40..87 (47 + len byte)
        writeBoundedString(s: event.flow.linkId, into: &bytes, lenAt: 11, dataAt: 40, maxLen: 48)
        // localAddrLen at 88, localAddress at 89..167 (79)
        writeBoundedString(s: event.flow.key.localAddress, into: &bytes, lenAt: 88, dataAt: 89, maxLen: 79)
        // remoteAddrLen at 168, remoteAddress at 169..247 (79)
        writeBoundedString(s: event.flow.key.remoteAddress, into: &bytes, lenAt: 168, dataAt: 169, maxLen: 79)
        // isRealtime at 248 (u8 flag); padding 249..255 stays zero.
        bytes[248] = event.flow.isRealtime ? 1 : 0

        let slot = UInt64(writeIndex % UInt64(capacity))
        let offset = UInt64(FlowStatsPublisher.headerSize) + slot * UInt64(FlowStatsPublisher.recordSize)
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: bytes)
        } catch {
            log.error("flow_stats: record write failed: \(error.localizedDescription)")
            return
        }

        // Bump writeIndex (header offset 16). We use seek+write rather than a
        // mmap atomic because Foundation's FileHandle doesn't expose memory
        // barriers; readers that catch a torn writeIndex will just re-poll.
        writeIndex &+= 1
        var idxBytes = [UInt8](repeating: 0, count: 8)
        writeUInt64LE(value: writeIndex, into: &idxBytes, at: 0)
        do {
            try handle.seek(toOffset: 16)
            try handle.write(contentsOf: idxBytes)
        } catch {
            log.error("flow_stats: writeIndex bump failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Byte helpers ---------------------------------------------------

    private func writeUInt16LE(value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset]     = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func writeUInt32LE(value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset]     = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func writeUInt64LE(value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        for i in 0..<8 {
            bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i))
        }
    }

    private func readUInt64LE(from bytes: Data, at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(bytes[bytes.startIndex + offset + i]) << (8 * i)
        }
        return v
    }

    /// Encode `s` UTF-8, truncating to `maxLen` bytes. Stores the length at
    /// `lenAt` and the bytes starting at `dataAt`. Truncates safely at a UTF-8
    /// scalar boundary so the reader never sees a half-encoded codepoint.
    private func writeBoundedString(
        s: String,
        into bytes: inout [UInt8],
        lenAt: Int,
        dataAt: Int,
        maxLen: Int
    ) {
        var data = Array(s.utf8)
        if data.count > maxLen {
            // Walk back to the last valid scalar boundary <= maxLen.
            var cut = maxLen
            while cut > 0 && (data[cut] & 0xC0) == 0x80 {
                cut -= 1
            }
            data = Array(data.prefix(cut))
        }
        bytes[lenAt] = UInt8(truncatingIfNeeded: data.count)
        for i in 0..<data.count {
            bytes[dataAt + i] = data[i]
        }
    }
}
