// PacketTunnelProvider.swift
//
// Entry point for the ArcaneDispatch Network Extension. The extension owns the
// macOS system-wide TUN device and (in later phases) the bonded transport
// engine. In Phase 5 it forwards packets through a userspace TCP/UDP NAT that
// reuses the existing per-link source-address dispatch logic — system-wide
// reach without any bonded-protocol work yet.
//
// XCODE WIRE-UP (one-time, must be done outside this file):
// 1. In Xcode → File → New → Target → "Network Extension" (macOS).
//    Product Name: ArcaneDispatchTunnel
//    Bundle Identifier: art.arcane.ArcaneDispatch.tunnel
//    Embed in App: ArcaneDispatch (Runner)
// 2. Move every `.swift` under `macos/ArcaneDispatchTunnel/` into the new
//    target's Compile Sources.
// 3. Move `ArcaneDispatchTunnel.entitlements` into the target's Build
//    Settings → Code Signing Entitlements.
// 4. Move `Info.plist` into the target's Build Settings → Info.plist File.
// 5. Add capabilities (signed by your Apple Dev account):
//    - App Sandbox: ON
//    - Network Extensions: Packet Tunnel
//    - App Groups: group.art.arcane.dispatch
// 6. The container app target ("Runner") needs the matching App Group and the
//    `com.apple.developer.networking.networkextension = [packet-tunnel-provider]`
//    entitlement (already updated in `macos/Runner/{Debug,Release}Profile.entitlements`).
// 7. Both targets must use the SAME Apple Developer team and have provisioning
//    profiles that include the NetworkExtension capability.

import Foundation
import NetworkExtension
import OSLog

/// `NEPacketTunnelProvider` subclass that owns the tunnel lifecycle.
///
/// The extension communicates with the container app via the App Group
/// container (shared file system + atomically rewritten policy JSON) and via
/// `NETunnelProviderSession.sendProviderMessage` for ad-hoc RPC.
///
/// Threading: every NetworkExtension callback arrives on a serial queue
/// owned by the system. Anything async must be marshalled onto our own
/// dispatch queues (see `PacketPump`).
@objc(PacketTunnelProvider)
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "art.arcane.dispatch.tunnel", category: "provider")
    private let policyStore = PolicyStore()
    private var pump: PacketPump?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        log.info("startTunnel: invoked")

        // Phase 1: read the policy snapshot from the VPN configuration's
        // `providerConfiguration` dict. The container app stashes it there
        // before saveToPreferences so we don't need an App Group container.
        // Phase 2 (fallback): if the dict is missing the key — older
        // configurations, or a future App-Group rollout that pushes policy
        // via the shared file system — read from the App Group container.
        let providerConfig =
            (protocolConfiguration as? NETunnelProviderProtocol)?
                .providerConfiguration
        let inlinePolicyJson = providerConfig?["policy"] as? String
        let policy: ExtensionPolicy?
        if let json = inlinePolicyJson,
           let data = json.data(using: .utf8),
           let parsed = try? JSONDecoder()
                .decode(ExtensionPolicy.self, from: data) {
            log.info("startTunnel: loaded policy from providerConfiguration (\(parsed.links.count) links)")
            policy = parsed
        } else {
            if inlinePolicyJson != nil {
                log.error("startTunnel: providerConfiguration[policy] present but un-decodable; falling back to App Group")
            }
            policy = policyStore.load()
        }

        guard let policy = policy else {
            log.error("startTunnel: no policy available (providerConfiguration empty and App Group container missing)")
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        log.info("startTunnel: policy ready with \(policy.links.count) links")

        // Tunnel network settings: minimal IPv4 for Phase 5; IPv6 + custom DNS
        // come in Phase 6 once we drive routing decisions per-flow.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.42.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        settings.mtu = NSNumber(value: 1400)
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error = error {
                self.log.error("setTunnelNetworkSettings failed: \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            self.log.info("startTunnel: tunnel network settings applied")
            // Hand the packet flow off to the pump. The pump runs on its own
            // dispatch queue and stays alive until `stopTunnel` cancels it.
            self.pump = PacketPump(packetFlow: self.packetFlow, policy: policy)
            self.pump?.start()
            completionHandler(nil)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.info("stopTunnel: reason=\(String(describing: reason))")
        pump?.stop()
        pump = nil
        completionHandler()
    }

    /// RPC bridge from the container app. The Dart side calls this when it
    /// wants the extension to reload policy without disconnecting.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        log.debug("handleAppMessage: \(messageData.count) bytes")
        guard let message = try? JSONDecoder().decode(TunnelMessage.self, from: messageData) else {
            log.error("handleAppMessage: malformed payload")
            completionHandler?(nil)
            return
        }
        switch message.kind {
        case .reloadPolicy:
            // Phase 1: prefer the inline JSON payload — works even when the
            // extension is sandboxed away from any App Group container.
            // Phase 2 (fallback): if the payload is absent or malformed
            // and we do have an App Group container, re-read from disk so
            // older container builds keep working.
            let updated: ExtensionPolicy?
            if let json = message.policyJson,
               let data = json.data(using: .utf8),
               let parsed = try? JSONDecoder()
                    .decode(ExtensionPolicy.self, from: data) {
                updated = parsed
            } else {
                if message.policyJson != nil {
                    log.error("handleAppMessage: inline reloadPolicy payload un-decodable; falling back to App Group")
                }
                updated = policyStore.load()
            }
            if let updated = updated {
                log.info("handleAppMessage: reloaded policy with \(updated.links.count) links")
                pump?.applyPolicy(updated)
                completionHandler?(Data("ok".utf8))
            } else {
                log.error("handleAppMessage: reloadPolicy failed (no inline payload and no policy.json)")
                completionHandler?(nil)
            }
        case .ping:
            completionHandler?(Data("pong".utf8))
        case .getThroughput:
            // Drain the per-link byte accumulators built up by the
            // forwarder since the previous RPC. Returns a JSON list of
            // `{linkId, bytesIn, bytesOut}` the container app turns into
            // bytes-per-second `LinkMetric` events for the UI's bond
            // graphic particle flow and bandwidth readouts.
            guard let pump = pump else {
                completionHandler?(Data("[]".utf8))
                return
            }
            let snap = pump.drainThroughputForRPC()
            // `JSONSerialization` is fine here — the keys are static
            // ASCII and the values are scalar Int / String.
            if let data = try? JSONSerialization.data(
                withJSONObject: snap, options: []) {
                completionHandler?(data)
            } else {
                completionHandler?(Data("[]".utf8))
            }
        }
    }
}

/// Minimal envelope for `handleAppMessage`. Kept on the extension side so
/// adding a new RPC verb only touches this file (and its mirror in the
/// container app's `TunnelManager`).
struct TunnelMessage: Codable {
    enum Kind: String, Codable {
        case reloadPolicy
        case ping
        /// Drain the forwarder's per-link bytes-since-last-drain counters.
        /// Response is a JSON array of `{linkId, bytesIn, bytesOut}` objects
        /// (Int values); empty array when the tunnel isn't pumping yet.
        case getThroughput
    }

    let kind: Kind
    /// Optional inline policy JSON for `reloadPolicy`. Travels in-band so
    /// the extension can apply a new snapshot without reading the App Group
    /// container (which is unavailable when the entitlement is missing).
    let policyJson: String?
}
