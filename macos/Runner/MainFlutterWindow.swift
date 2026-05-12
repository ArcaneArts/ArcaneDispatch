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

    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()
    self.orderOut(nil)
  }
}
