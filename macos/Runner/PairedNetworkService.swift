//
//  PairedNetworkService.swift
//
//  Bonjour-based Pair & Share discovery.
//
//  Publishes ourselves as `_arcane-dispatch._tcp` so peer Macs on the
//  same LAN can find us, and browses for other instances. The discovery
//  surface is symmetric with the Dart `PairDiscovery` abstraction in
//  `lib/paired/pair_beacon.dart` so the cross-platform UI can speak to
//  either fake (loopback tests) or real (Bonjour) backends.
//
//  Wire payload: each `NetService` carries a TXT record with the same
//  fields as `PairBeacon.toJson()` minus the `host` (the framework hands
//  us that separately) and `port` (carried by the service itself).
//
//  Threading: `NSNetServiceBrowser` is main-thread by convention. We
//  marshal all events into a single Combine subject and forward to the
//  Flutter MethodChannel from there.
//

import Foundation
import Network

@available(macOS 10.15, *)
public final class PairedNetworkService: NSObject {
    public typealias PeerEvent = (kind: PeerEventKind, peer: PeerSnapshot)

    public enum PeerEventKind { case found, lost }

    public struct PeerSnapshot: Codable, Equatable {
        public let deviceId: String
        public let deviceName: String
        public let host: String
        public let port: Int
        public let fingerprint: String
        public let version: String
    }

    public static let serviceType = "_arcane-dispatch._tcp"

    // MARK: - State

    private let queue = DispatchQueue(label: "art.arcane.dispatch.pair-discovery")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var publishedRecord: NWTXTRecord?
    private var publishedPort: NWEndpoint.Port?
    private var publishedDevice: PeerSnapshot?
    private var peers: [String: PeerSnapshot] = [:]
    private var subscribers: [(PeerEvent) -> Void] = []

    // MARK: - Publishing

    /// Begin advertising `self` to the local network. Calling twice updates
    /// the broadcast in-place.
    @discardableResult
    public func publish(_ snapshot: PeerSnapshot) -> Bool {
        queue.sync { publishedDevice = snapshot }
        let txt = NWTXTRecord([
            "deviceId": snapshot.deviceId,
            "deviceName": snapshot.deviceName,
            "fingerprint": snapshot.fingerprint,
            "version": snapshot.version,
        ])
        let service = NWListener.Service(
            name: snapshot.deviceName,
            type: PairedNetworkService.serviceType,
            domain: nil,
            txtRecord: txt
        )

        do {
            let port = NWEndpoint.Port(integerLiteral: UInt16(snapshot.port))
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let l = try NWListener(using: params, on: port)
            l.service = service
            l.newConnectionHandler = { [weak self] conn in
                // We don't accept incoming pair connections here — the
                // handshake runs over a normal TCP socket once the joiner
                // dials the advertised host:port directly. Reject so the
                // browser stays a pure discovery surface.
                self?.queue.async { conn.cancel() }
            }
            l.start(queue: queue)
            queue.sync {
                self.listener?.cancel()
                self.listener = l
                self.publishedRecord = txt
                self.publishedPort = port
            }
            return true
        } catch {
            NSLog("PairedNetworkService.publish failed: \(error)")
            return false
        }
    }

    public func unpublish() {
        queue.sync {
            listener?.cancel()
            listener = nil
            publishedDevice = nil
            publishedRecord = nil
            publishedPort = nil
        }
    }

    // MARK: - Browsing

    /// Begin browsing. Subscribers receive snapshots for every peer seen.
    public func startBrowsing(_ sink: @escaping (PeerEvent) -> Void) {
        queue.async {
            self.subscribers.append(sink)
            // Replay cache first.
            for peer in self.peers.values {
                sink((.found, peer))
            }
            guard self.browser == nil else { return }
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
                type: PairedNetworkService.serviceType,
                domain: nil
            )
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let b = NWBrowser(for: descriptor, using: params)
            b.browseResultsChangedHandler = { [weak self] results, changes in
                self?.handleBrowseChanges(results: results, changes: changes)
            }
            b.start(queue: self.queue)
            self.browser = b
        }
    }

    public func stopBrowsing() {
        queue.sync {
            browser?.cancel()
            browser = nil
            subscribers.removeAll()
        }
    }

    // MARK: - Snapshot

    public var snapshot: [PeerSnapshot] {
        queue.sync { Array(peers.values) }
    }

    // MARK: - Internals

    private func handleBrowseChanges(
        results: Set<NWBrowser.Result>,
        changes: Set<NWBrowser.Result.Change>
    ) {
        // Recompute the diff: we treat each `NWBrowser.Result` as a
        // candidate peer. The fingerprint+deviceId in the TXT record is
        // the join key.
        var nextPeers: [String: PeerSnapshot] = [:]
        for result in results {
            guard let peer = snapshotFromResult(result) else { continue }
            // Ignore our own advertisement.
            if let self_ = publishedDevice, peer.deviceId == self_.deviceId {
                continue
            }
            nextPeers[peer.deviceId] = peer
        }

        let oldKeys = Set(peers.keys)
        let newKeys = Set(nextPeers.keys)
        let added = newKeys.subtracting(oldKeys)
        let removed = oldKeys.subtracting(newKeys)

        for k in added {
            if let p = nextPeers[k] { broadcast((.found, p)) }
        }
        for k in removed {
            if let p = peers[k] { broadcast((.lost, p)) }
        }
        peers = nextPeers
    }

    private func snapshotFromResult(_ result: NWBrowser.Result) -> PeerSnapshot? {
        guard case .bonjour(let txt) = result.metadata else { return nil }
        let deviceId = txt["deviceId"] ?? ""
        let deviceName = txt["deviceName"] ?? deviceId
        let fingerprint = txt["fingerprint"] ?? ""
        let version = txt["version"] ?? "1"
        if deviceId.isEmpty || fingerprint.isEmpty { return nil }
        // Endpoint resolution happens later via the resolver hook on the
        // Dart side; for the snapshot we record the advertised port + a
        // placeholder host. The bonded transport rediscovers the IP at
        // connect time using the standard Bonjour endpoint.
        var host = ""
        let port = 0
        if case .service(_, _, _, _) = result.endpoint {
            // Service endpoints don't expose the resolved tuple until
            // they're connected to. Surface the raw description so the
            // UI can debug and Dart can issue a real `NWConnection` for
            // the handshake.
            host = result.endpoint.debugDescription
        }
        return PeerSnapshot(
            deviceId: deviceId,
            deviceName: deviceName,
            host: host,
            port: port,
            fingerprint: fingerprint,
            version: version
        )
    }

    private func broadcast(_ event: PeerEvent) {
        for sink in subscribers {
            sink(event)
        }
    }
}
