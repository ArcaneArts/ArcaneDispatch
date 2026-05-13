// PolicyStore.swift
//
// App Group bridge — reads the latest policy snapshot the Dart container app
// writes to `Library/Application Support/policy.json` inside the shared
// container at `group.art.arcane.dispatch`.
//
// Authoritative schema: `docs/policy_schema.json` (JSON-Schema 2020-12).
// Dart emitter: `lib/core/policy.dart::Policy.toJson`. Bump
// `Policy.schemaVersion` (Dart) and the `version` const in
// `docs/policy_schema.json` in lockstep with any breaking change here.
//
// Minimal example (full schema in docs/policy_schema.json):
//
// {
//   "version": 1,
//   "mode": "speed",
//   "killSwitch": false,
//   "links": [
//     {
//       "id": "en0",
//       "label": "WiFi",
//       "interfaceName": "en0",
//       "sourceAddress": "10.0.0.4",
//       "weight": 1,
//       "priority": "primary",
//       "speedCapBps": null,
//       "dataCapBytes": null,
//       "dataUsedBytes": 0
//     }
//   ]
// }

import Foundation
import OSLog

/// Mirrors the Dart `Link` struct closely enough for the engine's needs.
/// We deliberately omit fields that only the UI cares about (label, status)
/// from the optional set so we never fail to decode a policy because of UI
/// drift.
struct PolicyLink: Codable {
    let id: String
    let label: String?
    let interfaceName: String?
    let sourceAddress: String?
    let weight: Int?
    let priority: String?
    let speedCapBps: Int?
    let dataCapBytes: Int?
    let dataUsedBytes: Int?
}

/// Minimal policy view consumed by the extension.
struct ExtensionPolicy: Codable {
    let version: Int
    let mode: String
    let killSwitch: Bool
    let links: [PolicyLink]
    /// Relay URL for the server-backed tunnel, for example
    /// `udp://relay.example.com:4430` or `relay.example.com:4430`.
    let serverUrl: String?
    /// Bearer token staged by the container app. Auth is negotiated by the
    /// relay handshake; PacketPump only needs to know whether relay mode is
    /// configured.
    let serverToken: String?
    /// When true, PacketPump routes outbound packets through the bonded
    /// relay path. A non-empty serverUrl also enables relay mode so older
    /// UI builds that only set the endpoint still get the intended path.
    let bondedTransport: Bool?
    /// When true, the container app's `CaptivePortalDetector` is allowed
    /// to demote links via policy updates. The extension itself doesn't
    /// probe — it only reacts to whatever priorities the container has
    /// pushed. Defaults to `false` when absent so older Dart builds keep
    /// working unchanged.
    let captivePortalAssist: Bool?
}

/// Reads the policy JSON from the App Group container. Writes are done by the
/// Dart side via `PathProviderFoundation`/`Hive` — the extension is read-only.
final class PolicyStore {
    private let log = Logger(subsystem: "art.arcane.dispatch.tunnel", category: "policy")
    private let appGroupId = "group.art.arcane.dispatch"
    private let fileName = "policy.json"

    /// Resolve the policy file path inside the App Group container. Returns
    /// `nil` only if the entitlement is missing (entitlement misconfig).
    private var policyURL: URL? {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            log.error("App Group container missing — check entitlements for \(self.appGroupId)")
            return nil
        }
        return containerURL.appendingPathComponent(fileName)
    }

    /// Load the latest policy snapshot. Returns `nil` if the file doesn't
    /// exist yet (first launch before Dart has written one) or if it's
    /// malformed.
    func load() -> ExtensionPolicy? {
        guard let url = policyURL else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.info("policy.json absent — extension will idle until Dart writes one")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let policy = try JSONDecoder().decode(ExtensionPolicy.self, from: data)
            return policy
        } catch {
            log.error("policy.json decode failed: \(error.localizedDescription)")
            return nil
        }
    }
}
