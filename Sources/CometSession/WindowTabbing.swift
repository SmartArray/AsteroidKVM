import AppKit

// Window tabs are opt-in so captured Tab keys belong to the remote computer by default.
@MainActor public enum WindowTabbing {
  public static let preferenceKey = "enableWindowTabs"
  private static let remoteIdentifier = "AsteroidKVM.Remote"
  public static var enabled: Bool { UserDefaults.standard.bool(forKey: preferenceKey) }

  public static func configure(_ window: NSWindow) {
    window.tabbingIdentifier = remoteIdentifier
    window.tabbingMode = enabled ? .preferred : .disallowed
  }

  public static func applyToOpenWindows() {
    NSWindow.allowsAutomaticWindowTabbing = enabled
    for window in NSApp.windows where window.tabbingIdentifier == remoteIdentifier {
      if !enabled, (window.tabbedWindows?.count ?? 0) > 1 {
        window.moveTabToNewWindow(nil)
      }
      configure(window)
    }
  }
}
