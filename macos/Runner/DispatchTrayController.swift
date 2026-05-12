import Cocoa
import FlutterMacOS

final class DispatchTrayController: NSObject {
  static let shared = DispatchTrayController()

  private var statusItem: NSStatusItem?
  private weak var window: NSWindow?
  private var channel: FlutterMethodChannel?

  private override init() {
    super.init()
  }

  func attach(window: NSWindow, channel: FlutterMethodChannel) {
    self.window = window
    self.channel = channel
  }

  func install() {
    if !Thread.isMainThread {
      DispatchQueue.main.async {
        self.install()
      }
      return
    }

    if statusItem != nil {
      return
    }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = NSStatusItem.AutosaveName("ArcaneDispatchTray")
    item.isVisible = true
    statusItem = item
    configureButton(item)
  }

  func bounds() -> [String: Double]? {
    if !Thread.isMainThread {
      return DispatchQueue.main.sync {
        self.bounds()
      }
    }
    guard let buttonWindow = statusItem?.button?.window else {
      return nil
    }
    let frame = buttonWindow.frame
    guard let screen = buttonWindow.screen ?? NSScreen.screens.first else {
      return nil
    }
    let screenFrame = screen.frame
    let flippedY = screenFrame.origin.y + screenFrame.height - frame.origin.y - frame.height
    return [
      "x": Double(frame.origin.x),
      "y": Double(flippedY),
      "width": Double(frame.width),
      "height": Double(frame.height),
    ]
  }

  func setTooltip(_ tooltip: String) {
    if !Thread.isMainThread {
      DispatchQueue.main.async {
        self.setTooltip(tooltip)
      }
      return
    }
    statusItem?.button?.toolTip = tooltip
  }

  func setActivationPolicy(_ mode: String) {
    if !Thread.isMainThread {
      DispatchQueue.main.async {
        self.setActivationPolicy(mode)
      }
      return
    }
    switch mode {
    case "regular":
      NSApp.setActivationPolicy(.regular)
    case "accessory":
      NSApp.setActivationPolicy(.accessory)
    case "prohibited":
      NSApp.setActivationPolicy(.prohibited)
    default:
      break
    }
  }

  private func configureButton(_ item: NSStatusItem) {
    guard let button = item.button else {
      return
    }
    button.image = loadIcon()
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.title = ""
    button.toolTip = "Arcane Dispatch"
    button.target = self
    button.action = #selector(handleStatusItemClick(_:))
    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    item.menu = nil
  }

  private func loadIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18))
    image.lockFocus()
    NSColor.labelColor.setStroke()
    NSColor.labelColor.setFill()

    let transform = NSAffineTransform()
    transform.translateX(by: 9, yBy: 9)
    transform.rotate(byDegrees: -18)
    transform.translateX(by: -9, yBy: -9)
    transform.concat()

    let portal = NSBezierPath(ovalIn: NSRect(x: 3.3, y: 4.2, width: 11.4, height: 8.4))
    portal.lineWidth = 1.8
    portal.stroke()

    let inner = NSBezierPath(ovalIn: NSRect(x: 5.7, y: 5.9, width: 6.6, height: 5.0))
    inner.lineWidth = 1.0
    inner.stroke()

    for rect in [
      NSRect(x: 2.5, y: 7.0, width: 2.6, height: 2.6),
      NSRect(x: 11.9, y: 2.9, width: 2.3, height: 2.3),
      NSRect(x: 13.7, y: 11.5, width: 2.4, height: 2.4),
    ] {
      NSBezierPath(ovalIn: rect).fill()
    }
    image.unlockFocus()
    image.isTemplate = true
    return image
  }

  @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    let rightClick = event?.type == .rightMouseUp
    let controlClick = event?.type == .leftMouseUp &&
      event?.modifierFlags.contains(.control) == true

    if rightClick || controlClick {
      let menu = makeMenu()
      if let event = event {
        NSMenu.popUpContextMenu(menu, with: event, for: sender)
      } else {
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
      }
    } else {
      channel?.invokeMethod("onLeftClick", arguments: nil)
    }
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(menuItem(title: "Show Arcane Dispatch", key: "show"))
    menu.addItem(menuItem(title: "Hide Arcane Dispatch", key: "hide"))
    menu.addItem(NSMenuItem.separator())
    menu.addItem(menuItem(title: "Quit Arcane Dispatch", key: "exit"))
    return menu
  }

  private func menuItem(title: String, key: String) -> NSMenuItem {
    let item = NSMenuItem(
      title: title,
      action: #selector(handleMenuItemClick(_:)),
      keyEquivalent: ""
    )
    item.target = self
    item.representedObject = key
    return item
  }

  @objc private func handleMenuItemClick(_ sender: NSMenuItem) {
    let key = sender.representedObject as? String ?? ""
    channel?.invokeMethod("onMenuItem", arguments: ["key": key])
  }
}
