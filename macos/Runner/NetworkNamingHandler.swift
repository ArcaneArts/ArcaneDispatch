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
//   * We shell out to `/usr/sbin/networksetup` rather than calling
//     CoreWLAN's `CWInterface.ssid()` directly because the latter started
//     requiring **Location Services** permission in macOS 14, and we don't
//     want a "Dispatch wants to use your location" prompt just to read a
//     network name. The `networksetup -getairportnetwork` path has no
//     permission gate.
//   * CoreWLAN is still used as a *fallback* and for richer per-interface
//     attributes the shell can't expose (active channel, RSSI). Phase 15.+
//     can read those for the per-link cards.
//   * Output is intentionally JSON-serialisable so the channel can hand the
//     list straight to Flutter without an extra encode step.

import Cocoa
import CoreWLAN
import FlutterMacOS

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

final class NetworkNamingHandler {
    static let shared = NetworkNamingHandler()

    private let channelName = "art.arcane.dispatch/naming"
    private let networksetupPath = "/usr/sbin/networksetup"

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
            case "ssid":
                let args = call.arguments as? [String: Any]
                let bsd = (args?["bsdName"] as? String) ?? ""
                result(self.currentSsid(forBsd: bsd))
            default:
                result(FlutterMethodNotImplemented)
            }
        }
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
