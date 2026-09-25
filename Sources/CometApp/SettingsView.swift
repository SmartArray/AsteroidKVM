import CometCore
import CometMedia
import CometSession
// Keep device configuration in native Settings and distinguish Mac behavior from remote USB changes.
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject var model: AppModel
  @AppStorage("appearance") private var appearance = "System"
  private let sections = [
    "General", "Connections", "Display", "Devices", "Transcription", "Keyboard & Clipboard", "MCP", "Appearance", "System",
    "Advanced",
  ]

  // Present native settings sections while keeping device selection explicit.
  var body: some View {
    NavigationSplitView {
      List(sections, id: \.self, selection: $model.settingsSection) { Text($0) }
        .navigationSplitViewColumnWidth(
          170)
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(model.settingsSection).font(.title2.bold())
          switch model.settingsSection {
          case "General":
            Text(
              "Open a saved Comet from Connections. Each remote window keeps its own video, authentication, and input state."
            )
            LabeledContent("Release remote input", value: "⌃⌥⌘Esc")
            LabeledContent("Toggle fullscreen", value: "⌃⌘F")
            Text(
              "Click the remote display to capture input. The first click captures; subsequent clicks go to the remote computer."
            ).foregroundStyle(.secondary)
          case "Connections": connectionSettings
          case "Transcription": TranscriptionSettingsView()
          case "Display":
            devicePicker
            if let id = model.selectedDevice, let session = model.sessions[id] {
              DisplaySettingsView(session: session)
                .id("\(session.id)|\(session.profile.baseURL?.absoluteString ?? "")")
            } else {
              Text("Connect a device to configure its display.").foregroundStyle(.secondary)
            }
          case "Devices":
            devicePicker
            if let id = model.selectedDevice, let session = model.sessions[id] {
              DeviceSettings(session: session)
            } else {
              Text("Connect a device to discover its supported settings.").foregroundStyle(
                .secondary)
            }
          case "Keyboard & Clipboard":
            devicePicker
            if let id = model.selectedDevice, let session = model.sessions[id] {
              NativeTypingSettings(session: session)
            } else {
              Text("Select a connection to configure its typing interval.").foregroundStyle(.secondary)
            }
            Text(
              "Target layouts, Native Keyboard Layout, and paste are configured per connection using the Keyboard toolbar."
            )
            Text(
              "Physical key input works without the daemon patch. Native typing requires the mapped_text capability. Dead keys compose locally; Option+N then Space types ~. Committed text must be supported by the target keymap."
            ).foregroundStyle(.secondary)
            Text(
              "Clipboard content is never stored. Paste operations send at most 16,384 Unicode scalars and are never automatically retried."
            )
          case "MCP":
            devicePicker
            Group {
              if let id = model.selectedDevice, let session = model.sessions[id] {
                MCPSettingsView(session: session, server: session.mcpServer).id(id)
              } else {
                Text("Select a connection to configure its MCP server.").foregroundStyle(.secondary)
              }
            }.task(id: model.selectedDevice) {
              if let id = model.selectedDevice { _ = model.session(for: id) }
            }
          case "Appearance":
            Picker("Appearance", selection: $appearance) {
              Text("System").tag("System")
              Text("Light").tag("Light")
              Text("Dark").tag("Dark")
            }
            .onChange(of: appearance) { _, value in
              NSApp.appearance =
                value == "System" ? nil : NSAppearance(named: value == "Dark" ? .darkAqua : .aqua)
            }
          case "System":
            Text("Hardware Identity").font(.headline)
            Text(
              "Reserved for future hardware identity configuration, including supported USB descriptors. Display identity is available in Display settings."
            )
            Text(
              "USB identity changes are not available in this version. Future providers will expose preview, validation, apply, and restore operations only when the device supports them."
            ).foregroundStyle(.secondary)
          default:
            Text("Native WebRTC and Metal").font(.headline)
            Text(
              "Requires macOS 14 or later. H.264 uses WebRTC’s VideoToolbox decoder where available. Other negotiated codecs may decode in software. HEVC decoding is not provided by the pinned WebRTC build."
            )
            Text(
              "Diagnostics are available in each connection’s Actions menu. Frame queues are bounded; performance measurements describe local rendering and network RTT, not end-to-end latency."
            ).foregroundStyle(.secondary)
          }
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
      }
    }.frame(width: 760, height: 540)
  }

  // Identify the exact saved or ephemeral Comet whose settings will be changed.
  private var devicePicker: some View {
    Picker("Configure Comet", selection: $model.selectedDevice) {
      Text("Select a connection").tag(UUID?.none)
      ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
      ForEach(
        model.sessions.values.filter { session in
          !model.profiles.contains(where: { $0.id == session.id })
        }
      ) { Text($0.profile.name).tag(Optional($0.id)) }
    }
  }

  // Keep password deletion and certificate trust reset explicit for each saved connection.
  private var connectionSettings: some View {
    VStack(alignment: .leading, spacing: 16) {
      ForEach(model.profiles) { profile in
        HStack {
          VStack(alignment: .leading) {
            Text(profile.name).font(.headline)
            Text(profile.username + " · " + profile.host).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Remove Saved Password") {
            do {
              try PasswordStore().remove(for: profile)
              var updated = profile
              updated.rememberPassword = false
              try model.save(updated, password: nil)
              model.sessions[profile.id]?.updateProfile { $0.rememberPassword = false }
            } catch { model.error = error.localizedDescription }
          }
          if profile.certificateSHA256 != nil {
            Button("Reset Certificate Trust") {
              Task {
                do {
                  var updated = profile
                  updated.certificateSHA256 = nil
                  await model.sessions[profile.id]?.replaceProfile(updated, password: nil)
                  try model.save(updated, password: nil)
                } catch { model.error = error.localizedDescription }
              }
            }.help("Ends this connection and requires certificate approval on the next sign-in.")
          }
        }
      }
      Text(
        "Logging out does not remove saved passwords. Password removal is an explicit Keychain operation."
      ).font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct DeviceSettings: View {
  @ObservedObject var session: SessionController
  private let functionLabels = [
    "enable_keyboard": "USB keyboard", "enable_mouse": "USB mouse",
    "enable_mouse_alt": "Alternate USB mouse", "start_cdrom": "Virtual CD-ROM",
    "start_flash": "Virtual flash drive", "enable_mic": "USB microphone",
    "enable_audio": "USB audio", "enable_speaker": "USB speaker", "enable_camera": "USB camera",
    "enable_mtp": "Media transfer (MTP)",
  ]

  // Expose only confirmed device controls and separate local capture from appliance changes.
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(session.profile.name).font(.headline)
      if !session.active {
        Text("Connect this Comet to configure its devices.").foregroundStyle(.secondary)
      }
      GroupBox("Audio on This Mac") {
        VStack(alignment: .leading, spacing: 12) {
          Toggle(
            "Mute remote playback",
            isOn: Binding(
              get: { session.profile.muted },
              set: { value in session.updateProfile { $0.muted = value } }))
          Toggle(
            "Forward this Mac’s microphone",
            isOn: Binding(get: { session.microphone }, set: { session.setMicrophone($0) })
          )
          .disabled(!session.active || session.mediaFeatures["mic"].bool != true)
          if session.mediaFeatures["mic"].bool != true {
            Text("Microphone forwarding is not advertised by the media service.").font(.caption)
              .foregroundStyle(.secondary)
          }
        }.padding(8)
      }
      GroupBox("Comet USB Devices") {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(functionLabels.keys.sorted(), id: \.self) { key in
            if let value = session.state.functions[key].bool {
              Toggle(
                functionLabels[key]!,
                isOn: Binding(
                  get: { session.state.functions[key].bool ?? value },
                  set: { session.setDevice(key, value: $0) })
              )
              .disabled(!session.active)
            }
          }
          if session.state.functions == .null {
            Text("This firmware does not expose USB function controls.").foregroundStyle(.secondary)
          }
          Text("Changing USB functions can briefly reconnect the attached computer’s USB devices.")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(8)
      }
      GroupBox("Mouse & Keyboard") {
        VStack(alignment: .leading, spacing: 12) {
          if session.state.system["absolute_mouse"].bool != nil {
            Picker(
              "Mouse mode",
              selection: Binding(
                get: { session.state.system["absolute_mouse"].bool ?? true },
                set: { session.setSystemParameter("absolute_mouse", value: String($0)) })
            ) {
              Text("Absolute").tag(true)
              Text("Relative").tag(false)
            }
          }
          if session.state.hid["jiggler"]["enabled"].bool == true {
            Toggle(
              "Run Comet mouse jiggler",
              isOn: Binding(
                get: { session.state.hid["jiggler"]["active"].bool ?? false },
                set: { session.setHID("jiggler", value: String($0)) }))
            JigglerSettingsView(session: session)
          }
          ForEach(
            [
              ("keyboard", "Keyboard output", "keyboard_output"),
              ("mouse", "Mouse output", "mouse_output"),
            ], id: \.0
          ) { subsystem, label, key in
            let options = session.state.hid[subsystem]["outputs"]["available"].array.compactMap(
              \.string)
            if !options.isEmpty {
              Picker(
                label,
                selection: Binding(
                  get: { session.state.hid[subsystem]["outputs"]["active"].text },
                  set: { session.setHID(key, value: $0) })
              ) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
              }
            }
          }
          // These controls affect capture on this Mac; USB device toggles above configure the appliance.
          Toggle(
            "Send keyboard input from this Mac",
            isOn: Binding(
              get: { session.profile.keyboardEnabled },
              set: { value in session.updateProfile { $0.keyboardEnabled = value } }))
          Toggle(
            "Send mouse input from this Mac",
            isOn: Binding(
              get: { session.profile.mouseEnabled },
              set: { value in session.updateProfile { $0.mouseEnabled = value } }))
          Toggle(
            "Reverse scrolling",
            isOn: Binding(
              get: { session.profile.reverseScrolling },
              set: { value in session.updateProfile { $0.reverseScrolling = value } }))
          HStack {
            Text("Mouse polling interval")
            Slider(
              value: Binding(
                get: { session.profile.mousePollingMilliseconds },
                set: { value in session.updateProfile { $0.mousePollingMilliseconds = value } }),
              in: 1...50, step: 1)
            Text("\((Int(exactly: session.profile.mousePollingMilliseconds) ?? 10)) ms")
              .monospacedDigit()
          }
          Text("Local relative mouse sensitivity")
          Slider(
            value: Binding(
              get: { session.profile.mouseSensitivity },
              set: { value in session.updateProfile { $0.mouseSensitivity = value } }), in: 0.1...4)
          Text("Local scroll sensitivity")
          Slider(
            value: Binding(
              get: { session.profile.scrollSensitivity },
              set: { value in session.updateProfile { $0.scrollSensitivity = value } }), in: 0.1...4
          )
        }.padding(8)
      }
      GroupBox("Text Recognition") {
        Picker(
          "Recognition language",
          selection: Binding(
            get: { session.ocrLanguages.first ?? "" },
            set: { session.ocrLanguages = $0.isEmpty ? [] : [$0] })
        ) {
          Text("Automatic").tag("")
          ForEach((try? TextRecognition.languages()) ?? [], id: \.self) {
            Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0)
          }
        }.padding(8)
      }
    }
  }
}

// Store pacing per connection and apply changes to the active output queue.
struct NativeTypingSettings: View {
  @ObservedObject var session: SessionController

  var body: some View {
    GroupBox("Native Keyboard Layout") {
      VStack(alignment: .leading, spacing: 10) {
        Stepper(
          "Typing interval: \(session.profile.nativeTypingIntervalMilliseconds) ms",
          value: Binding(
            get: { session.profile.nativeTypingIntervalMilliseconds },
            set: { value in session.updateProfile { $0.nativeTypingIntervalMilliseconds = value } }),
          in: 0...1000, step: 10
        ).accessibilityIdentifier("native-typing-interval")
        Text("Delay after each character when Use Native Keyboard Layout is enabled. Lower values type faster; 0 ms removes the added delay. If symbols become incorrect, increase the interval. Default: \(ConnectionProfile.defaultNativeTypingIntervalMilliseconds) ms.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Reset to \(ConnectionProfile.defaultNativeTypingIntervalMilliseconds) ms") {
          session.updateProfile { $0.nativeTypingIntervalMilliseconds = ConnectionProfile.defaultNativeTypingIntervalMilliseconds }
        }.disabled(session.profile.nativeTypingIntervalMilliseconds == ConnectionProfile.defaultNativeTypingIntervalMilliseconds)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}


struct MCPSettingsView: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject var session: SessionController
  @ObservedObject var server: DeviceMCPServer
  @State private var port = ""
  @State private var notice: String?

  private func update(_ change: (inout MCPPreferences) -> Void) {
    session.updateProfile {
      var preferences = $0.mcp ?? MCPPreferences()
      change(&preferences)
      $0.mcp = preferences
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Give an MCP client access to this device only. Keep AsteroidKVM running and connect the device for screen and input tools.")
      Toggle("Enable MCP for this device", isOn: Binding(
        get: { session.profile.mcp?.enabled ?? false },
        set: { value in
          var selectedPort = session.profile.mcp?.port ?? 9101
          if value, session.profile.mcp == nil {
            let used = Set(model.sessions.values.filter { $0.id != session.id && $0.profile.mcp?.enabled == true }
              .compactMap { $0.profile.mcp?.port })
            while used.contains(selectedPort), selectedPort < 65535 { selectedPort += 1 }
          }
          update { $0.enabled = value; $0.port = selectedPort }
          port = String(selectedPort)
        }))
        .accessibilityIdentifier("mcp-enable")
      HStack {
        TextField("Local port", text: $port).frame(width: 160)
          .accessibilityIdentifier("mcp-port")
        Button("Apply Port") {
          guard let value = Int(port), (1024...65535).contains(value) else {
            notice = "Choose a port between 1024 and 65535."; return
          }
          update { $0.port = value }; notice = nil
        }
      }
      Toggle("Allow keyboard and mouse control", isOn: Binding(
        get: { session.profile.mcp?.allowControl ?? false },
        set: { value in update { $0.allowControl = value } }))
      Text("When off, clients can only inspect the screen, read text, and wait for changes.")
        .font(.caption).foregroundStyle(.secondary)
      LabeledContent("Endpoint", value: server.endpoint).textSelection(.enabled)
      LabeledContent("Status", value: server.status)
      HStack {
        Button("Copy MCP Configuration") {
          do {
            let configuration = try server.configuration()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(configuration, forType: .string)
            notice = "Configuration copied, including this device’s access token."
          } catch { notice = error.localizedDescription }
        }.disabled(session.profile.mcp?.enabled != true)
        Button("Regenerate Token") { server.regenerateToken() }
          .disabled(session.profile.mcp?.enabled != true)
      }
      Text("Each device needs a different port. Tokens are stored in Keychain. Regenerating a token disconnects existing MCP clients.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Stop Automation") {
          server.pauseControl(); session.interruptAutomation(); session.releaseCapture()
        }.accessibilityIdentifier("mcp-stop")
        if server.paused {
          Button("Resume MCP Control") { server.resumeControl() }
        }
      }
      Text("Stop shortcut: ⌃⌥⌘Esc while AsteroidKVM is active. Manual takeover pauses MCP control until you resume it here.")
        .font(.caption).foregroundStyle(.secondary)
      if let notice { Text(notice).font(.caption) }
      Divider()
      Text("Connected Clients").font(.headline)
      if server.clients.isEmpty { Text("No MCP clients connected.").foregroundStyle(.secondary) }
      ForEach(Array(server.clients.enumerated()), id: \.offset) { _, name in Text(name) }
      Text("Clients expire after five minutes without requests. Input ownership expires after 30 idle seconds; operations time out after two minutes.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Recent Activity").font(.headline)
      Text("Kept in memory only. Typed text and screenshots are not included.").font(.caption).foregroundStyle(.secondary)
      ForEach(server.history.prefix(20)) { item in
        HStack {
          Text(item.date, style: .time)
          Text(item.client)
          Text(item.tool).font(.system(.caption, design: .monospaced))
          Spacer()
          Text(item.outcome)
        }.font(.caption)
      }
    }.onAppear { port = String(session.profile.mcp?.port ?? 9101) }
  }
}
