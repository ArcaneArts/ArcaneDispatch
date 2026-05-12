import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  /// Stop the system-wide tunnel before AppKit tears the process down so
  /// the macOS network stack doesn't keep routing all traffic into a dead
  /// `utun*` interface. Without this, quitting the app leaves the
  /// computer offline for several seconds while the OS GC's the orphaned
  /// route.
  ///
  /// `NSApplication.TerminateReply.terminateLater` lets us wait up to ~2 s
  /// for `NETunnelProviderManager.connection.stopVPNTunnel()` to round-trip
  /// to the extension and bring the route down cleanly. The actual stop is
  /// fire-and-forget from the extension's side, so a 2 s ceiling is plenty.
  override func applicationShouldTerminate(_ sender: NSApplication)
      -> NSApplication.TerminateReply {
    TunnelManager.shared.stopBeforeQuit { [weak sender] in
      sender?.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
