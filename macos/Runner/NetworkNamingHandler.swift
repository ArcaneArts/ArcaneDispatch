// NetworkNamingHandler.swift
//
// macOS-side resolver that turns raw BSD interface names (`en0`, `en7`,
// `pdp_ip0`, …) into something a user actually recognises:
//   * The Wi-Fi network SSID for Wi-Fi interfaces.
//   * The "Hardware Port" name from `networksetup` for everything else
//     (e.g. "USB 10/100/1000 LAN", "iPhone USB", "Bluetooth PAN").
//   * A coarse [kind] string the Dart side maps to icons + sort buckets.
//
// Channel name: `art.arcane.dispatch/naming`. Mirror in Dart at
// `lib/platform/network_naming_service.dart`.
//
// Implementation notes:
//   * macOS 14+ gates the Wi-Fi SSID behind Location Services
//     authorization, on **both** code paths (`CWInterface.ssid()` AND
//     `networksetup -getairportnetwork`). We request `When In Use`
//     authorization at app launch with a copy that explains we only
//     read the SSID — no location data is collected.
//   * Once the user has granted permission, `CWInterface.ssid()`
//     returns the live SSID directly; we fall back to the
//     `networksetup` shell route on the off-chance CoreWLAN is acting
//     up for a particular adapter.
//   * Output is intentionally JSON-serialisable so the channel can hand the
//     list straight to Flutter without an extra encode step.

import Cocoa
import CoreLocation
import CoreWLAN
import FlutterMacOS
import os.log

/// Coarse kind used by the UI to pick icons and sort buckets. Mirrors
/// `NamedInterfaceKind` on the Dart side.
private enum NamedKind: String {
    case wifi
    case ethernet
    case cellularTether
    case bluetoothTether
    case thunderbolt
    case loopback
    case virtualTunnel
    case bridge
    case other
}

/// Single hardware-port → BSD mapping pulled from `networksetup`.
private struct HardwarePort {
    let port: String      // "Wi-Fi", "USB 10/100/1000 LAN", "iPhone USB"
    let device: String    // "en0", "en7", "en9"
    let mac: String?      // colon-separated, may be nil for virtual ports
}

/// One row from `networksetup -listnetworkserviceorder`. This is what
/// System Settings → Network shows: the *saved* services, regardless of
/// whether the hardware is currently attached.
private struct NetworkService {
    let serviceName: String   // "Wi-Fi", "iPhone USB", "USB 10/100/1000 LAN 2"
    let hardwarePort: String  // "Wi-Fi", "iPhone USB", "com.connectify.Speedify"
    let device: String        // "en0", "en8", "" for virtual VPN services
    let disabled: Bool        // True iff the service is starred (* in the listing)

    /// True for VPN-like services we don't want to surface as adoptable
    /// networks. The signal: empty BSD device combined with a reverse-DNS
    /// `hardwarePort` (`com.connectify.Speedify`, `ch.protonvpn.mac`,
    /// `art.arcane.ArcaneDispatch`, …). Real network services either have
    /// a BSD device or a human-readable port name.
    var isVPNLike: Bool {
        if !device.isEmpty { return false }
        // No device and the port name looks like a bundle identifier.
        let lp = hardwarePort.lowercased()
        return lp.contains(".") && !lp.contains(" ")
    }
}

final class NetworkNamingHandler: NSObject, CLLocationManagerDelegate {
    static let shared = NetworkNamingHandler()

    private let channelName = "art.arcane.dispatch/naming"
    private let networksetupPath = "/usr/sbin/networksetup"

    /// Owns the Location permission lifecycle for CoreWLAN's SSID
    /// readback. macOS 14+ requires `When In Use` authorization before
    /// `CWInterface.ssid()` will return anything other than nil. The
    /// permission flow:
    ///
    ///   1. On app launch we instantiate the manager + assign self as
    ///      delegate. macOS checks the current authorization status.
    ///   2. If still `.notDetermined`, we call
    ///      `requestWhenInUseAuthorization` once. The user sees the
    ///      standard system prompt with our `NSLocationUsageDescription`
    ///      copy explaining we only need it for the Wi-Fi name.
    ///   3. Once `authorizedAlways` or `authorizedWhenInUse` arrives via
    ///      `locationManagerDidChangeAuthorization`, every subsequent
    ///      SSID call hits CoreWLAN happy-path.
    ///
    /// We never start location updates — only the authorization is
    /// needed for `ssid()`, so no power / privacy footprint beyond
    /// "permission granted".
    private let locationManager = CLLocationManager()

    private override init() {
        super.init()
        locationManager.delegate = self
        // Reading status synchronously is the documented way to drive
        // the first-time prompt. The delegate callback fires on
        // subsequent permission changes.
        //
        // We dispatch the actual `requestWhenInUseAuthorization` call
        // onto the main runloop's next tick so the AppKit event loop is
        // alive by the time macOS tries to surface the permission
        // sheet. Calling it directly inside `init()` (which runs from
        // `NetworkNamingHandler.shared` access during
        // `applicationDidFinishLaunching`) sometimes drops the prompt
        // on the floor under macOS 26 because the alert host hasn't
        // attached to the app yet.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let status = self.locationManager.authorizationStatus
            os_log("location: initial status=%{public}d", log: .default, type: .info, status.rawValue)
            if status == .notDetermined {
                os_log("location: requesting When-In-Use authorization", log: .default, type: .info)
                self.locationManager.requestWhenInUseAuthorization()
            } else if status == .denied || status == .restricted {
                os_log("location: denied/restricted — Wi-Fi SSIDs will be unavailable. Grant access in System Settings > Privacy & Security > Location Services.", log: .default, type: .error)
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        os_log("location: authorization changed to %{public}d", log: .default, type: .info, status.rawValue)
    }

    func register(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: controller.engine.binaryMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(FlutterMethodNotImplemented); return
            }
            switch call.method {
            case "list":
                result(self.listInterfaces())
            case "listKnownServices":
                result(self.listKnownServices())
            case "ssid":
                let args = call.arguments as? [String: Any]
                let bsd = (args?["bsdName"] as? String) ?? ""
                result(self.currentSsid(forBsd: bsd))
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Returns SAVED + AVAILABLE network services as System Settings →
    /// Network displays them, NOT just the hardware ports that are
    /// currently attached. The list includes:
    ///
    ///   * Wi-Fi (en0) — with current SSID when associated.
    ///   * Ethernet adapters whether plugged in or not (the user can
    ///     plug them in later and Dispatch will pick them up).
    ///   * `iPhone USB`, `Bluetooth PAN`, USB-tether adapters — saved
    ///     entries so the user *knows* Dispatch will leverage them when
    ///     they connect their phone or pair a tether device.
    ///   * Bluetooth PAN — surfaced even when no Bluetooth-tether device
    ///     is currently paired, with `isCurrentlyAvailable=false`, so
    ///     the UI can suggest pairing one.
    ///
    /// Each entry carries `isCurrentlyAvailable=true` iff the BSD device
    /// is listed by `ifconfig -lu` (i.e. up + reachable). Per-service
    /// VPN entries (PairVPN, ProtonVPN, Speedify, Arcane Dispatch
    /// itself) are filtered out — they're virtual transports built on
    /// top of the other links, not networks the user "connects to".
    func listKnownServices() -> [[String: Any?]] {
        let services = parseNetworkServices()
        let upBSD = activeBSDInterfaces()
        var out: [[String: Any?]] = []
        for svc in services {
            // Skip VPN entries — those are routing layers, not networks
            // the user would expect to see in a network-picker.
            if svc.isVPNLike { continue }
            let kind = classify(port: svc.hardwarePort, bsd: svc.device)
            let isUp = !svc.device.isEmpty && upBSD.contains(svc.device)
            var entry: [String: Any?] = [
                "serviceName": svc.serviceName,
                "hardwarePort": svc.hardwarePort,
                "bsdName": svc.device.isEmpty ? nil : svc.device,
                "kind": kind.rawValue,
                "isCurrentlyAvailable": isUp,
                "disabled": svc.disabled,
            ]
            if kind == .wifi && isUp {
                entry["ssid"] = currentSsid(forBsd: svc.device)
            } else {
                entry["ssid"] = nil
            }
            out.append(entry)
        }
        return out
    }

    // MARK: - Public entry points

    /// Returns one entry per macOS hardware port. Each entry contains the
    /// BSD device name, the friendly hardware port name, an optional SSID
    /// for Wi-Fi ports, and a coarse [kind] enum string. Filtering /
    /// sorting / fallback labelling is left to the Dart side so the
    /// UX rules live in one place.
    func listInterfaces() -> [[String: Any?]] {
        let ports = parseHardwarePorts()
        var out: [[String: Any?]] = []
        for hp in ports {
            let kind = classify(port: hp.port, bsd: hp.device)
            var entry: [String: Any?] = [
                "bsdName": hp.device,
                "hardwarePort": hp.port,
                "macAddress": hp.mac,
                "kind": kind.rawValue,
            ]
            if kind == .wifi {
                entry["ssid"] = currentSsid(forBsd: hp.device)
            } else {
                entry["ssid"] = nil
            }
            out.append(entry)
        }
        return out
    }

    /// Returns the SSID currently associated with [bsd], or nil when the
    /// interface is disconnected / not a Wi-Fi adapter.
    func currentSsid(forBsd bsd: String) -> String? {
        // Try CoreWLAN first; on macOS 13- it returns the SSID without any
        // entitlement. On 14+ it returns nil unless Location is granted,
        // which we then fall back to the shell route for.
        if let client = CWWiFiClient.shared().interface(withName: bsd),
           let ssid = client.ssid(), !ssid.isEmpty {
            return ssid
        }
        let raw = runShell(networksetupPath, ["-getairportnetwork", bsd])
        // Output: "Current Wi-Fi Network: MyHomeWifi\n" or
        //         "You are not associated with an AirPort network.\n"
        guard let colon = raw.range(of: ": ") else {
            return nil
        }
        let value = raw[colon.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty
            || value.lowercased().contains("not associated")
            || value.lowercased().contains("not enabled") {
            return nil
        }
        return value
    }

    // MARK: - Parsing

    /// Parse `networksetup -listnetworkserviceorder`. Output looks like:
    ///
    ///     An asterisk (*) denotes that a network service is disabled.
    ///     (1) Wi-Fi
    ///     (Hardware Port: Wi-Fi, Device: en0)
    ///
    ///     (2) iPhone USB
    ///     (Hardware Port: iPhone USB, Device: en8)
    ///
    ///     (3) PairVPN
    ///     (Hardware Port: com.mobileco.PairVPN, Device: )
    ///
    /// We walk the lines two at a time: a numbered service header followed
    /// by its `(Hardware Port: …, Device: …)` continuation line.
    private func parseNetworkServices() -> [NetworkService] {
        let raw = runShell(networksetupPath, ["-listnetworkserviceorder"])
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        var services: [NetworkService] = []
        var pendingName: String?
        var pendingDisabled: Bool = false

        for rawLine in lines {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Detail rows are the form `(Hardware Port: …, Device: …)` —
            // they wrap their whole contents in a single set of parens.
            if line.hasPrefix("(Hardware Port:") {
                guard let svcName = pendingName else { continue }
                // Drop the leading `(` and trailing `)` so the field
                // extractor doesn't need to handle them.
                var detail = line
                detail.removeFirst()
                if detail.hasSuffix(")") {
                    detail.removeLast()
                }
                let hp = extractField(detail, key: "Hardware Port:", terminator: ",")
                let dev = extractEnd(detail, key: "Device:")
                services.append(NetworkService(
                    serviceName: svcName,
                    hardwarePort: hp,
                    device: dev,
                    disabled: pendingDisabled
                ))
                pendingName = nil
                pendingDisabled = false
                continue
            }
            // Header rows are `(N) Service Name` or `(N)* Disabled Service`.
            // Skip anything else (e.g. the banner about `*` semantics).
            guard line.hasPrefix("("), let closeParen = line.firstIndex(of: ")") else {
                continue
            }
            // Confirm the part between the parens is purely numeric.
            let between = line[line.index(after: line.startIndex)..<closeParen]
            let digitsOnly = between.allSatisfy { $0.isNumber }
            if !digitsOnly { continue }
            let afterParen = line.index(after: closeParen)
            var rest = String(line[afterParen...])
                .trimmingCharacters(in: .whitespaces)
            var disabled = false
            if rest.hasPrefix("*") {
                disabled = true
                rest = String(rest.dropFirst())
                    .trimmingCharacters(in: .whitespaces)
            }
            pendingName = rest
            pendingDisabled = disabled
        }
        return services
    }

    /// Pulls `value` out of a string like
    /// `Hardware Port: Wi-Fi, Device: en0`. Returns "" when the field is
    /// missing.
    private func extractField(_ s: String, key: String, terminator: Character) -> String {
        guard let keyRange = s.range(of: key) else { return "" }
        let after = s[keyRange.upperBound...]
        guard let term = after.firstIndex(of: terminator) else {
            return after.trimmingCharacters(in: .whitespaces)
        }
        return after[..<term].trimmingCharacters(in: .whitespaces)
    }

    /// Same as [extractField] but returns everything from `key` to the
    /// end of the string. Used for the last field on a row (`Device: enX`
    /// where the closing paren has already been trimmed).
    private func extractEnd(_ s: String, key: String) -> String {
        guard let keyRange = s.range(of: key) else { return "" }
        return s[keyRange.upperBound...]
            .trimmingCharacters(in: .whitespaces)
    }

    /// Set of BSD interface names that are currently UP (i.e. listed by
    /// `ifconfig -lu`). Used to decide whether a saved network service
    /// is "Connected" or "Disconnected" without having to enumerate
    /// addresses on each interface.
    private func activeBSDInterfaces() -> Set<String> {
        let raw = runShell("/sbin/ifconfig", ["-lu"])
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        return Set(trimmed.split(separator: " ").map { String($0) })
    }

    private func parseHardwarePorts() -> [HardwarePort] {
        let raw = runShell(networksetupPath, ["-listallhardwareports"])
        var ports: [HardwarePort] = []
        var port: String?
        var device: String?
        var mac: String?
        func flush() {
            if let p = port, let d = device, !d.isEmpty {
                ports.append(HardwarePort(port: p, device: d, mac: mac))
            }
            port = nil; device = nil; mac = nil
        }
        for raw in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                continue
            }
            if let v = stripped(line, prefix: "Hardware Port: ") {
                // New stanza begins; flush the previous one.
                flush()
                port = v
            } else if let v = stripped(line, prefix: "Device: ") {
                device = v
            } else if let v = stripped(line, prefix: "Ethernet Address: ") {
                let trimmed = v.trimmingCharacters(in: .whitespaces)
                mac = trimmed.lowercased() == "n/a" ? nil : trimmed
            }
        }
        flush()
        return ports
    }

    private func stripped(_ s: String, prefix: String) -> String? {
        guard s.hasPrefix(prefix) else { return nil }
        return String(s.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Classification

    /// Maps a hardware-port name + BSD device into a coarse [NamedKind].
    /// The rules are designed to be readable and easy to extend; they do
    /// **not** try to be exhaustive — anything we can't bucket lands in
    /// `.other` and the Dart side displays the raw port name.
    private func classify(port: String, bsd: String) -> NamedKind {
        let lp = port.lowercased()
        let lb = bsd.lowercased()
        if lp.contains("wi-fi") || lp.contains("airport") {
            return .wifi
        }
        if lp.contains("ethernet") || lp.contains("lan") || lp.hasPrefix("usb 10")
            || lp.contains("rj45") {
            return .ethernet
        }
        if lp.contains("thunderbolt bridge") || lp.contains("bridge") {
            return .bridge
        }
        if lp.contains("thunderbolt") {
            return .thunderbolt
        }
        if lp.contains("iphone") || lp.contains("ipad") || lp.contains("usb modem")
            || lp.contains("cellular") {
            return .cellularTether
        }
        if lp.contains("bluetooth") {
            return .bluetoothTether
        }
        if lb.hasPrefix("utun") || lb.hasPrefix("ipsec") || lb.hasPrefix("tun")
            || lb.hasPrefix("tap") || lb.hasPrefix("ppp") {
            return .virtualTunnel
        }
        if lb.hasPrefix("lo") {
            return .loopback
        }
        return .other
    }

    // MARK: - Shell

    /// Tiny synchronous shell helper. Used only for short commands whose
    /// output is < 16 KB (`networksetup -listallhardwareports`,
    /// `networksetup -getairportnetwork enX`). Anything heavier should
    /// stream via a Pipe with a delegate.
    private func runShell(_ launchPath: String, _ args: [String]) -> String {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return ""
        }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
