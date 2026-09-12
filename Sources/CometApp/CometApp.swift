import CometCore
import CometSession
// Use native scene, menu, and Settings conventions while each remote window owns its session view.
import SwiftUI

@main struct CometApp: App {
  @StateObject private var model = AppModel()
  @NSApplicationDelegateAdaptor(CometApplicationDelegate.self) private var appDelegate
  @Environment(\.openWindow) private var openWindow

  // Declare native scenes and local menu commands around the shared profile registry.
  var body: some Scene {
    Window("Connections", id: "connections") {
      ConnectionManagerView().environmentObject(model).onAppear {
        appDelegate.model = model
        let appearance = UserDefaults.standard.string(forKey: "appearance") ?? "System"
        NSApp.appearance =
          appearance == "System"
          ? nil : NSAppearance(named: appearance == "Dark" ? .darkAqua : .aqua)
      }
    }
    .defaultSize(width: 650, height: 440)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Connections…") { openWindow(id: "connections") }.keyboardShortcut("n")
      }
      CommandGroup(after: .windowArrangement) {
        Button("Enter Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.keyboardShortcut(
          "f", modifiers: [.control, .command])
        Button("Release Remote Input") { model.sessions.values.forEach { $0.releaseCapture() } }
          .keyboardShortcut(.escape, modifiers: [.control, .option, .command])
      }
    }
    WindowGroup("Comet", for: UUID.self) { $id in
      if let id, let session = model.session(for: id) {
        SessionView(session: session).environmentObject(model)
      } else {
        // Restored ephemeral IDs cannot be reopened; bring the manager forward instead of leaving a blank window.
        ContentUnavailableView {
          Label("Connection Unavailable", systemImage: "desktopcomputer")
        } description: {
          Text("Open a saved connection or add a Comet from Connections.")
        } actions: {
          Button("Open Connections") { openWindow(id: "connections") }
        }.task { openWindow(id: "connections") }
      }
    }
    .defaultSize(width: 1200, height: 760)
    Settings { SettingsView().environmentObject(model) }
  }
}

// Hold termination until each session has released input and closed its own media and network resources.
@MainActor final class CometApplicationDelegate: NSObject, NSApplicationDelegate {
  weak var model: AppModel?

  // Allow each session to release input before the application finishes quitting.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model else { return .terminateNow }
    Task {
      for session in model.sessions.values { await session.disconnect() }
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
