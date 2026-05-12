import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    self.orderOut(nil)

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    self.isOpaque = false
    self.backgroundColor = NSColor.clear
    flutterViewController.backgroundColor = NSColor.clear
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.hasShadow = false
    self.isMovableByWindowBackground = false
    if #available(macOS 11.0, *) {
      self.titlebarSeparatorStyle = .none
    }

    let trayChannel = FlutterMethodChannel(
      name: "dispatch_tray",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    DispatchTrayController.shared.attach(window: self, channel: trayChannel)
    trayChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "init":
        DispatchTrayController.shared.install()
        result(nil)
      case "getBounds":
        result(DispatchTrayController.shared.bounds())
      case "setTooltip":
        let arguments = call.arguments as? [String: Any]
        let tooltip = arguments?["tooltip"] as? String ?? "Arcane Dispatch"
        DispatchTrayController.shared.setTooltip(tooltip)
        result(nil)
      case "setActivationPolicy":
        let arguments = call.arguments as? [String: Any]
        let mode = arguments?["mode"] as? String ?? "accessory"
        DispatchTrayController.shared.setActivationPolicy(mode)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // Phase 5: Network Extension bridge. Owns install/start/stop/policy push.
    // Channel name: `dispatch_tunnel` (mirror in lib/bridge/tunnel_channel.dart).
    TunnelManager.shared.register(with: flutterViewController)

    // Phase 13: Pair & Share discovery bridge. Wires the Bonjour-based
    // `PairedNetworkService` to the Dart `PairedMethodChannelDiscovery`.
    // Channel name: `dispatch_pair` (mirror in lib/paired/paired_channel.dart).
    if #available(macOS 10.15, *) {
      PairChannelHandler.shared.register(with: flutterViewController)
    }

    // UI: friendly SSID / hardware-port names. Resolves raw BSD interface
    // names (`en0`, `en7`) into "Home Wi-Fi", "USB 10/100/1000 LAN",
    // "iPhone USB", etc. so the network list reads like English.
    // Channel name: `art.arcane.dispatch/naming` (mirror in
    // `lib/platform/network_naming_service.dart`).
    NetworkNamingHandler.shared.register(with: flutterViewController)

    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()
    self.orderOut(nil)
  }
}
