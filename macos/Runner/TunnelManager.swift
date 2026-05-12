// TunnelManager.swift
//
// Container-app side of the Network Extension story. Owns:
// * The one-time `OSSystemExtensionRequest` to install/activate the
//   ArcaneDispatchTunnel.appex extension.
// * The `NETunnelProviderManager` that represents the active tunnel
//   configuration in System Preferences → VPN.
// * App Group bridge for writing the policy snapshot the extension reads on
//   startTunnel / reloadPolicy.
// * `dispatch_tunnel` MethodChannel handlers (wired in MainFlutterWindow).
//
// The Dart side (TunnelTransport) drives this via `MethodChannel`. See
// `lib/bridge/tunnel_channel.dart` for the API surface and `lib/transport/
// tunnel_transport.dart` for the consumer.
//
// Threading: NetworkExtension callbacks land on arbitrary queues; we marshal
// every cross-boundary call back to MainActor before invoking the channel
// handler so Flutter sees consistent threading.

import Cocoa
import CryptoKit
import FlutterMacOS
import NetworkExtension
import OSLog
import Security

/// Public method names on the `dispatch_tunnel` channel. Kept in this file so
/// adding a new RPC is a one-stop edit (Swift + Dart mirror in
/// `lib/bridge/tunnel_channel.dart`).
private enum TunnelMethod {
    static let installExtension = "installExtension"
    static let startTunnel      = "startTunnel"
    static let stopTunnel       = "stopTunnel"
    static let reloadPolicy     = "reloadPolicy"
    static let status           = "status"
    static let writePolicy      = "writePolicy"
    /// Returns the absolute filesystem path to `flow_stats.bin` inside the
    /// App Group container so the Dart `FlowStatsReader` can read the
    /// shared ring buffer the extension writes to.
    static let flowStatsPath    = "flowStatsPath"
    /// Persist the Speed Server endpoint + bearer token in the App Group
    /// container. Phase 9 will pin this against the real Noise IK
    /// handshake; for now the extension just stages it next to policy.json.
    static let setServer        = "setServer"
    /// Read the configured Speed Server back. Returns endpoint + a
    /// `tokenSet` flag — never the bearer secret itself.
    static let getServer        = "getServer"
    /// Returns this client's persistent Noise IK public key as a base64
    /// string. Generates a fresh keypair in Keychain on the first call.
    static let getClientPublicKey = "getClientPublicKey"
    /// Persists the responder's static public key (base64) so subsequent
    /// `startTunnel` calls can hand it to the extension via the App
    /// Group container. Pass empty to clear.
    static let setResponderPublicKey = "setResponderPublicKey"
    /// Asks the extension to drain its per-link byte counters since the
    /// previous call. Returns a JSON array of `{linkId, bytesIn,
    /// bytesOut}` objects. The Dart side polls this on a timer to drive
    /// the bond graphic's particle flow and per-link throughput chips.
    static let getThroughput = "getThroughput"
}

/// Tunnel status emitted to Dart. Mirror of `lib/bridge/tunnel_channel.dart::TunnelStatusKind`.
private enum TunnelStatus: String {
    case unknown
    case extensionMissing
    case stopped
    case starting
    case connected
    case stopping
    case failed
}

@objc public final class TunnelManager: NSObject {
    public static let shared = TunnelManager()

    private let log = Logger(subsystem: "art.arcane.dispatch", category: "tunnel-manager")
    private let extensionBundleId = "art.arcane.ArcaneDispatch.tunnel"
    private let appGroupId = "group.art.arcane.dispatch"
    private let policyFileName = "policy.json"
    /// File the extension reads to learn which Speed Server to bond to.
    /// Plain JSON: `{"endpoint":"host:port","token":"..."}`. Lives next
    /// to policy.json inside the App Group container so it inherits the
    /// same atomic-write guarantees and is unreadable to other processes
    /// on the box (App Group containers are per-team-id sandboxed).
    private let serverFileName = "server.json"

    private var manager: NETunnelProviderManager?
    private var lastError: String?

    public func register(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "dispatch_tunnel",
            binaryMessenger: controller.engine.binaryMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterMethodNotImplemented); return
            }
            self.handle(call: call, result: result)
        }
    }

    // MARK: - Channel routing

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        log.debug("channel call: \(call.method)")
        switch call.method {
        case TunnelMethod.installExtension:
            installExtension(result: result)
        case TunnelMethod.startTunnel:
            // Optional policyJson; if present we stash it on the VPN
            // configuration (`providerConfiguration`) AND write it to the
            // App Group container if entitled. The configuration dict
            // travels with the VPN profile so the extension always has a
            // policy even when App Groups isn't available — see
            // `loadOrCreateManager` for the wire-up.
            let pendingPolicyJson: String?
            if let args = call.arguments as? [String: Any],
               let json = args["policyJson"] as? String {
                pendingPolicyJson = json
                _ = writePolicy(jsonString: json)
            } else {
                pendingPolicyJson = nil
            }
            startTunnel(policyJson: pendingPolicyJson, result: result)
        case TunnelMethod.stopTunnel:
            stopTunnel(result: result)
        case TunnelMethod.reloadPolicy:
            // Always carry the JSON inline so the extension can hot-reload
            // even without an App Group container. We still attempt the
            // App Group write so a re-launched extension reads the same
            // snapshot via PolicyStore as a defence-in-depth fallback.
            guard let args = call.arguments as? [String: Any],
                  let json = args["policyJson"] as? String else {
                result(FlutterError(code: "bad_args",
                                    message: "policyJson required",
                                    details: nil))
                return
            }
            _ = writePolicy(jsonString: json) // best-effort
            sendReloadMessage(policyJson: json, result: result)
        case TunnelMethod.writePolicy:
            guard let args = call.arguments as? [String: Any],
                  let json = args["policyJson"] as? String else {
                result(FlutterError(code: "bad_args", message: "policyJson required", details: nil))
                return
            }
            result(writePolicy(jsonString: json))
        case TunnelMethod.status:
            result(currentStatusPayload())
        case TunnelMethod.flowStatsPath:
            result(flowStatsPath())
        case TunnelMethod.setServer:
            guard let args = call.arguments as? [String: Any],
                  let endpoint = args["endpoint"] as? String,
                  let token = args["token"] as? String else {
                result(FlutterError(code: "bad_args",
                                    message: "endpoint and token required",
                                    details: nil))
                return
            }
            result(setServer(endpoint: endpoint, token: token))
        case TunnelMethod.getServer:
            result(getServerPayload())
        case TunnelMethod.getClientPublicKey:
            do {
                let pub = try getOrCreateClientPublicKey()
                result(pub.base64EncodedString())
            } catch {
                result(FlutterError(code: "keychain_failed",
                                    message: error.localizedDescription, details: nil))
            }
        case TunnelMethod.setResponderPublicKey:
            guard let args = call.arguments as? [String: Any],
                  let pubB64 = args["publicKey"] as? String else {
                result(FlutterError(code: "bad_args",
                                    message: "publicKey required",
                                    details: nil))
                return
            }
            do {
                if pubB64.isEmpty {
                    try clearResponderPublicKey()
                } else {
                    guard let raw = Data(base64Encoded: pubB64), raw.count == 32 else {
                        result(FlutterError(code: "bad_pubkey",
                                            message: "publicKey must be 32 bytes base64",
                                            details: nil))
                        return
                    }
                    try saveResponderPublicKey(raw)
                }
                result(true)
            } catch {
                result(FlutterError(code: "keychain_failed",
                                    message: error.localizedDescription, details: nil))
            }
        case TunnelMethod.getThroughput:
            getThroughput(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Extension activation

    /// Confirm the bundled Packet Tunnel Provider is reachable.
    ///
    /// We ship the extension as an **App Extension** (`.appex` embedded in
    /// `Contents/PlugIns/`), not a System Extension (`.systemextension`).
    /// macOS auto-discovers app extensions when the host app is launched —
    /// there's no separate activation request. The VPN-configuration
    /// approval sheet appears later, when we first call
    /// `NETunnelProviderManager.saveToPreferences`.
    ///
    /// `OSSystemExtensionRequest` only works for `.systemextension` bundles
    /// and would hang forever waiting for an approval that the OS never
    /// surfaces for app-extension packaging — that's the bug behind the
    /// "stuck on Starting system-wide tunnel…" state.
    private func installExtension(result: @escaping FlutterResult) {
        let bundle = Bundle.main
        let plugInsURL = bundle.builtInPlugInsURL
        let expectedPath = plugInsURL?
            .appendingPathComponent("ArcaneDispatchTunnel.appex").path ?? "<unknown>"
        let present = FileManager.default.fileExists(atPath: expectedPath)
        log.info("installExtension: app-extension packaging — appex at \(expectedPath), present=\(present)")
        if !present {
            lastError = "Bundled Network Extension is missing at \(expectedPath). " +
                "Re-build with `flutter build macos` so the .appex is embedded."
            result(FlutterError(code: "appex_missing",
                                message: lastError, details: nil))
            return
        }
        // Clear any stale error so the UI doesn't keep showing a previous
        // failure once the user re-tries.
        lastError = nil
        result(true)
    }

    // MARK: - VPN configuration + connect

    /// Idempotently load (or create) our `NETunnelProviderManager` and start
    /// the tunnel. The user may see a "ArcaneDispatch wants to add VPN
    /// configurations" sheet on first run.
    ///
    /// `policyJson` is stashed on `NETunnelProviderProtocol.providerConfiguration`
    /// before `saveToPreferences` so the extension receives the snapshot even
    /// without an App Group container. When omitted, the previously-saved
    /// configuration is reused as-is.
    private func startTunnel(policyJson: String?, result: @escaping FlutterResult) {
        log.info("startTunnel: loading/creating NETunnelProviderManager (policy=\(policyJson != nil ? "fresh" : "reuse"))")
        loadOrCreateManager(policyJson: policyJson) { [weak self] manager, error in
            guard let self else { return }
            if let error = error {
                self.lastError = error.localizedDescription
                self.log.error("startTunnel/loadOrCreate failed: \(error.localizedDescription)")
                result(FlutterError(code: "vpn_load_failed",
                                    message: error.localizedDescription, details: nil))
                return
            }
            guard let manager = manager else {
                self.lastError = "No NETunnelProviderManager"
                result(FlutterError(code: "vpn_load_failed",
                                    message: "No NETunnelProviderManager", details: nil))
                return
            }
            manager.isEnabled = true
            // First save triggers the "ArcaneDispatch wants to add VPN
            // configurations" approval sheet. On subsequent saves the
            // call is silent.
            self.log.info("startTunnel: saveToPreferences (may show VPN-config dialog)")
            manager.saveToPreferences { saveError in
                if let saveError = saveError {
                    self.lastError = saveError.localizedDescription
                    self.log.error("startTunnel/save failed: \(saveError.localizedDescription)")
                    result(FlutterError(code: "vpn_save_failed",
                                        message: saveError.localizedDescription, details: nil))
                    return
                }
                self.log.info("startTunnel: saveToPreferences OK; reloading")
                manager.loadFromPreferences { loadError in
                    if let loadError = loadError {
                        self.lastError = loadError.localizedDescription
                        self.log.error("startTunnel/reload failed: \(loadError.localizedDescription)")
                        result(FlutterError(code: "vpn_reload_failed",
                                            message: loadError.localizedDescription, details: nil))
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                        self.lastError = nil
                        self.log.info("startTunnel: startVPNTunnel requested OK")
                        result(true)
                    } catch {
                        self.lastError = error.localizedDescription
                        self.log.error("startTunnel/connect failed: \(error.localizedDescription)")
                        result(FlutterError(code: "vpn_connect_failed",
                                            message: error.localizedDescription, details: nil))
                    }
                }
            }
        }
    }

    private func stopTunnel(result: @escaping FlutterResult) {
        guard let manager = manager else {
            result(true)
            return
        }
        manager.connection.stopVPNTunnel()
        log.info("stopTunnel: stop requested")
        result(true)
    }

    /// Synchronously requests tunnel shutdown and waits (up to a ceiling)
    /// for the OS to actually disconnect before calling [completion].
    /// Used by [AppDelegate.applicationShouldTerminate] so the user doesn't
    /// lose internet for several seconds after quitting the app.
    ///
    /// Implementation details:
    ///   * We load the manager fresh from preferences (the cached `manager`
    ///     may be nil if the app never started a tunnel itself but a prior
    ///     instance left one running).
    ///   * We poll `connection.status` so we can return as soon as the OS
    ///     confirms the route is down, rather than always waiting the full
    ///     ceiling.
    ///   * The ceiling is 2 seconds — long enough for a healthy stop on
    ///     normal hardware, short enough that the user doesn't experience
    ///     "the app is stuck quitting."
    @objc public func stopBeforeQuit(completion: @escaping () -> Void) {
        let ceiling: TimeInterval = 2.0
        let pollInterval: TimeInterval = 0.05
        let start = Date()

        NETunnelProviderManager.loadAllFromPreferences { [weak self] mgrs, _ in
            guard let self else { completion(); return }
            // Pick whichever manager actually owns our extension. There
            // should only ever be one, but be defensive.
            let mine = mgrs?.first { mgr in
                (mgr.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == self.extensionBundleId
            }
            guard let mgr = mine else {
                self.log.info("stopBeforeQuit: no tunnel installed; nothing to stop")
                completion()
                return
            }
            let state = mgr.connection.status
            if state == .disconnected || state == .invalid {
                self.log.info("stopBeforeQuit: already \(String(describing: state)); skipping stop")
                completion()
                return
            }
            self.log.info("stopBeforeQuit: requesting stop (state=\(String(describing: state)))")
            mgr.connection.stopVPNTunnel()

            // Poll the connection state until it's down or we hit the ceiling.
            func poll() {
                let elapsed = Date().timeIntervalSince(start)
                let now = mgr.connection.status
                if now == .disconnected || now == .invalid || elapsed >= ceiling {
                    self.log.info(
                        "stopBeforeQuit: settled (state=\(String(describing: now)), \(String(format: "%.2f", elapsed))s)")
                    completion()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) {
                    poll()
                }
            }
            poll()
        }
    }

    /// Resolve our manager (loading the existing one if any, otherwise
    /// creating a fresh `NETunnelProviderProtocol`).
    ///
    /// When `policyJson` is supplied we copy it into
    /// `proto.providerConfiguration["policy"]` so the running extension
    /// receives the snapshot via its `protocolConfiguration` (the standard
    /// NE pattern when App Groups isn't available). Re-setting this dict
    /// on every save is harmless — `saveToPreferences` is a no-op when
    /// nothing changed.
    private func loadOrCreateManager(
        policyJson: String?,
        _ completion: @escaping (NETunnelProviderManager?, Error?) -> Void
    ) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self else { return }
            if let error = error {
                self.log.error("loadOrCreate: loadAll failed: \(error.localizedDescription)")
                completion(nil, error); return
            }
            let existing = managers?.first { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == self.extensionBundleId
            }
            self.log.info("loadOrCreate: \(managers?.count ?? 0) configurations, existing=\(existing != nil)")
            let mgr = existing ?? NETunnelProviderManager()
            let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol)
                ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.extensionBundleId
            proto.serverAddress = "127.0.0.1" // unused for this provider
            // Plumb the policy snapshot through providerConfiguration so the
            // extension receives it without needing App Group access. The
            // existing dict is preserved on re-saves; only the `policy`
            // entry is replaced when a fresh snapshot is supplied.
            if let json = policyJson {
                var cfg = proto.providerConfiguration ?? [:]
                cfg["policy"] = json
                proto.providerConfiguration = cfg
                self.log.info("loadOrCreate: stashed \(json.utf8.count)-byte policy on providerConfiguration")
            }
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "Arcane Dispatch"
            mgr.isEnabled = true
            self.manager = mgr
            completion(mgr, nil)
        }
    }

    // MARK: - Policy IPC

    /// Write `policy.json` into the App Group container as a single atomic
    /// move. The extension polls + reloads on `handleAppMessage(reloadPolicy)`.
    @discardableResult
    private func writePolicy(jsonString: String) -> Bool {
        guard let data = jsonString.data(using: .utf8) else {
            log.error("writePolicy: bad utf8")
            return false
        }
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            log.error("writePolicy: App Group container not available")
            return false
        }
        let target = containerURL.appendingPathComponent(policyFileName)
        let temp = containerURL.appendingPathComponent("\(policyFileName).tmp")
        do {
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try? FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: target)
            }
            log.info("writePolicy: wrote \(data.count) bytes -> \(target.path)")
            return true
        } catch {
            log.error("writePolicy failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Send a `reloadPolicy` message to the running extension. The optional
    /// `policyJson` payload is carried in-band so the extension can hot-load
    /// the snapshot without needing an App Group container. No-op when the
    /// tunnel isn't connected; the extension picks up the new policy on its
    /// next startTunnel anyway (which we re-save with the latest
    /// `providerConfiguration["policy"]`).
    private func sendReloadMessage(policyJson: String?, result: @escaping FlutterResult) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            result(false); return
        }
        let payload = TunnelMessage(kind: .reloadPolicy, policyJson: policyJson)
        guard let data = try? JSONEncoder().encode(payload) else {
            result(FlutterError(code: "encode_failed",
                                message: "Could not encode reloadPolicy", details: nil))
            return
        }
        do {
            try session.sendProviderMessage(data) { response in
                result(response.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            }
        } catch {
            result(FlutterError(code: "send_failed",
                                message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - Status

    /// Drain the running extension's per-link byte counters. Returns an
    /// empty list when the tunnel isn't connected (the Dart side just
    /// emits zero deltas, which is what the UI expects when running but
    /// idle). The extension answers in JSON over `sendProviderMessage`
    /// — we decode and re-emit as a `[[String: Any]]` so the Flutter
    /// channel can serialise it without an extra hop through Data.
    private func getThroughput(result: @escaping FlutterResult) {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            result([[String: Any]]())
            return
        }
        let payload = TunnelMessage(kind: .getThroughput, policyJson: nil)
        guard let data = try? JSONEncoder().encode(payload) else {
            result([[String: Any]]())
            return
        }
        do {
            try session.sendProviderMessage(data) { response in
                guard let response = response,
                      let parsed = try? JSONSerialization.jsonObject(
                        with: response, options: []) as? [[String: Any]] else {
                    result([[String: Any]]())
                    return
                }
                result(parsed)
            }
        } catch {
            result([[String: Any]]())
        }
    }

    private func currentStatusPayload() -> [String: Any] {
        let kind: TunnelStatus
        if manager == nil {
            // We haven't created/loaded our config yet (no startTunnel
            // since launch). Report stopped — the host app's start
            // button is the canonical trigger that creates the manager.
            kind = .stopped
        } else {
            switch manager?.connection.status ?? .invalid {
            // `.invalid` on app-extension-packaged providers means the
            // OS hasn't loaded our manager yet, not that the extension
            // is missing (the .appex is embedded). Treat as stopped so
            // the UI doesn't show a misleading "extension missing"
            // sheet on the first poll.
            case .invalid:       kind = .stopped
            case .disconnected:  kind = .stopped
            case .connecting:    kind = .starting
            case .connected:     kind = .connected
            case .reasserting:   kind = .starting
            case .disconnecting: kind = .stopping
            @unknown default:    kind = .unknown
            }
        }
        return [
            "kind": kind.rawValue,
            "lastError": lastError ?? NSNull(),
            "extensionBundleId": extensionBundleId,
        ]
    }

    /// Absolute path to `flow_stats.bin` inside the App Group container, or
    /// nil when the entitlement is missing. Returned as a plain string so the
    /// Dart channel can hand it straight to `dart:io`.
    private func flowStatsPath() -> String? {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            log.error("flowStatsPath: App Group container missing — check entitlements")
            return nil
        }
        return containerURL.appendingPathComponent("flow_stats.bin").path
    }

    // MARK: - Speed Server config (Phase 8.12)

    /// Persist the configured Speed Server. Returns true on success. Empty
    /// `endpoint` AND empty `token` clears the file so the extension falls
    /// back to local mode.
    @discardableResult
    private func setServer(endpoint: String, token: String) -> Bool {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            log.error("setServer: App Group container missing — check entitlements")
            return false
        }
        let target = containerURL.appendingPathComponent(serverFileName)
        if endpoint.isEmpty && token.isEmpty {
            // Treat double-empty as "clear my config".
            try? FileManager.default.removeItem(at: target)
            log.info("setServer: cleared")
            return true
        }
        let payload = ServerConfig(endpoint: endpoint, token: token)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else {
            log.error("setServer: encode failed")
            return false
        }
        let temp = containerURL.appendingPathComponent("\(serverFileName).tmp")
        do {
            try data.write(to: temp, options: .atomic)
            // 0600 — read by the extension, write by the container app.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temp.path
            )
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try? FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: target)
            }
            log.info("setServer: wrote \(data.count) bytes -> \(target.path)")
            return true
        } catch {
            log.error("setServer failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Build the response payload for `getServer`. Endpoint is echoed
    /// verbatim; the bearer token is replaced with a `tokenSet` boolean so
    /// the secret never crosses the channel back into Dart.
    private func getServerPayload() -> [String: Any] {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return ["endpoint": "", "tokenSet": false]
        }
        let target = containerURL.appendingPathComponent(serverFileName)
        guard FileManager.default.fileExists(atPath: target.path),
              let data = try? Data(contentsOf: target),
              let cfg = try? JSONDecoder().decode(ServerConfig.self, from: data) else {
            return ["endpoint": "", "tokenSet": false]
        }
        return [
            "endpoint": cfg.endpoint,
            "tokenSet": !cfg.token.isEmpty,
        ]
    }

    // MARK: - Keychain (Phase 9.11)

    /// Service name shared with the System Extension so both targets
    /// resolve the same Keychain items. Bumping the suffix wipes stored
    /// keys (manual rotation lever).
    private let keychainService = "art.arcane.dispatch.crypto.v1"
    private let keychainClientAccount = "client-identity"
    private let keychainResponderAccount = "responder-public"

    /// Returns the client's X25519 public key, generating + persisting a
    /// fresh keypair on the first call.
    private func getOrCreateClientPublicKey() throws -> Data {
        if let priv = try loadKeychainData(account: keychainClientAccount) {
            guard priv.count == 32 else {
                throw KeychainError.badSize(priv.count)
            }
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: priv)
            return Data(key.publicKey.rawRepresentation)
        }
        // First-run: generate + persist.
        let key = Curve25519.KeyAgreement.PrivateKey()
        let priv = Data(key.rawRepresentation)
        try storeKeychainData(priv, account: keychainClientAccount)
        return Data(key.publicKey.rawRepresentation)
    }

    /// Persist (or replace) the responder's static public key.
    private func saveResponderPublicKey(_ pub: Data) throws {
        guard pub.count == 32 else { throw KeychainError.badSize(pub.count) }
        try storeKeychainData(pub, account: keychainResponderAccount)
    }

    /// Remove the cached responder key. No-op when absent.
    private func clearResponderPublicKey() throws {
        try deleteKeychainItem(account: keychainResponderAccount)
    }

    // MARK: - Keychain primitives

    private enum KeychainError: Error, CustomStringConvertible {
        case osStatus(OSStatus, String)
        case badSize(Int)

        var description: String {
            switch self {
            case .osStatus(let s, let op): return "keychain: \(op): OSStatus=\(s)"
            case .badSize(let n): return "keychain: bad key size \(n) (expected 32)"
            }
        }
    }

    private func loadKeychainData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status, "SecItemCopyMatching(\(account))")
        }
        return out as? Data
    }

    private func storeKeychainData(_ value: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        var attrs: [String: Any] = base
        attrs[kSecValueData as String] = value
        // Allow the System Extension to read after first unlock so the
        // tunnel can come up at login.
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(attrs as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: value]
            let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
            if updateStatus == errSecSuccess { return }
            throw KeychainError.osStatus(updateStatus, "SecItemUpdate(\(account))")
        }
        throw KeychainError.osStatus(addStatus, "SecItemAdd(\(account))")
    }

    private func deleteKeychainItem(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError.osStatus(status, "SecItemDelete(\(account))")
    }
}

// MARK: - Helpers

/// Mirror of the extension-side `TunnelMessage` so encode/decode stay in
/// lock-step. Kept private to this file because no other file in the runner
/// target sends extension messages.
private struct TunnelMessage: Codable {
    enum Kind: String, Codable {
        case reloadPolicy
        case ping
        /// Drain per-link byte counters from the extension. The reply
        /// is JSON `[{linkId, bytesIn, bytesOut}]` — see
        /// `PacketTunnelProvider.handleAppMessage(.getThroughput)`.
        case getThroughput
    }

    let kind: Kind
    /// Optional inline policy JSON for `reloadPolicy` so the extension can
    /// hot-load without reading the App Group container. Nil for other
    /// message kinds and back-compat with older container builds.
    let policyJson: String?

    init(kind: Kind, policyJson: String? = nil) {
        self.kind = kind
        self.policyJson = policyJson
    }
}

/// Persisted Speed Server credentials. Mirror of the Dart
/// `TunnelServerConfig` (without the bearer token round-tripped back).
/// Kept Codable so JSONEncoder/Decoder can do the IO; deliberately
/// internal to avoid the token leaking into other targets.
private struct ServerConfig: Codable {
    let endpoint: String
    let token: String
}

// Note: the OSSystemExtensionRequestDelegate plumbing that used to live here
// has been removed. The Packet Tunnel Provider is packaged as an App
// Extension (.appex embedded in Contents/PlugIns/), which macOS
// auto-discovers — no `OSSystemExtensionRequest` round-trip required. If we
// ever migrate to a System Extension (.systemextension), the delegate +
// `SystemExtensionOutcome` enum will need to come back along with the
// activation request in `installExtension`.

