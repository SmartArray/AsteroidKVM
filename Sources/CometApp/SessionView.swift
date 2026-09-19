import CometAgent
import CometCore
import CometSession
// Keep the remote image dominant and put occasional controls in compact native popovers.
import SwiftUI

struct SessionView: View {
  @ObservedObject var session: SessionController
  @EnvironmentObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @State private var keyboardOpen = false
  @State private var displayOpen = false
  @State private var diagnosticsOpen = false
  @State private var rebootConfirm = false
  @State private var loginPassword = ""

  // Keep live video dominant and place occasional controls in native popovers and sheets.
  var body: some View {
    ZStack {
      // Local controls keep focus while open; activating an unobstructed display grants remote input automatically.
      RemoteDisplayView(
        session: session,
        allowsAutomaticCapture: !keyboardOpen && !displayOpen && !diagnosticsOpen && !rebootConfirm)
      if !session.active && !session.ocrSelecting {
        VStack(spacing: 16) {
          Image(systemName: "desktopcomputer").font(.system(size: 42)).foregroundStyle(.secondary)
          Text(session.phase.rawValue).font(.title2)
          if session.phase == .authenticating {
            SecureField("Password", text: $loginPassword).textFieldStyle(.roundedBorder).frame(
              width: 240)
            Button("Sign In") {
              session.connect(password: loginPassword)
              loginPassword = ""
            }.buttonStyle(.borderedProminent)
          } else if session.phase == .disconnected {
            Button("Connect") { session.connect() }.buttonStyle(.borderedProminent)
              .accessibilityIdentifier("session-connect")
          } else {
            ProgressView().controlSize(.small)
          }
        }.padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
    .frame(minWidth: 640, minHeight: 400)
    .navigationTitle(session.profile.name)
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Menu {
          Button("Connection Manager…") {
            session.releaseCapture()
            openWindow(id: "connections")
          }
          ForEach(model.profiles) { profile in
            Button(profile.name) {
              session.releaseCapture()
              openWindow(value: profile.id)
              model.session(for: profile.id)?.connect()
            }
          }
          Divider()
          Button("Disconnect") { Task { await session.disconnect() } }.disabled(!session.active)
        } label: {
          Label("Connections", systemImage: "rectangle.stack")
        }.help("Connections")
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          session.releaseCapture()
          keyboardOpen.toggle()
        } label: {
          Label("Keyboard · \(session.profile.keymap.uppercased())", systemImage: "keyboard")
        }
        .popover(isPresented: $keyboardOpen) { KeyboardPopover(session: session) }
        .accessibilityIdentifier("keyboard-toolbar")
        Button {
          session.releaseCapture()
          displayOpen.toggle()
        } label: {
          Label("Display", systemImage: "display")
        }
        .popover(isPresented: $displayOpen) {
          DisplayPopover(session: session) {
            session.releaseCapture()
            model.selectedDevice = session.id
            model.settingsSection = "Display"
            displayOpen = false
            openSettings()
          }
        }
        .accessibilityIdentifier("display-toolbar")
        // Bind the native toggle to OCR state so Escape, completion, and another click clear its highlight.
        Toggle(
          isOn: Binding(
            get: { session.ocrSelecting },
            set: { selecting in
              if selecting { session.startOCR() } else { session.cancelOCR() }
            })
        ) {
          Label("Text Recognition", systemImage: "text.viewfinder")
        }
        .toggleStyle(.button)
        .accessibilityValue(session.ocrSelecting ? "On" : "Off")
        .disabled(!session.active || session.ocrBusy).help("Select text in the remote display")
        .accessibilityIdentifier("ocr-toolbar")
        Button {
          session.releaseCapture()
          openWindow(id: "agent", value: session.id)
        } label: {
          Label("Agent", systemImage: "bubble.left.and.text.bubble.right")
        }.help("Experimental Codex agent").accessibilityIdentifier("agent-toolbar")
        Menu {
          Button("Reboot Comet…") {
            session.releaseCapture()
            rebootConfirm = true
          }.disabled(!session.active)
          Button("Log Out") { Task { await session.disconnect(logout: true) } }
          Divider()
          Button("Diagnostics…") {
            session.releaseCapture()
            diagnosticsOpen = true
          }
        } label: {
          Label("Actions", systemImage: "ellipsis.circle")
        }.accessibilityIdentifier("actions-toolbar")
      }
    }
    .alert("Reboot Comet?", isPresented: $rebootConfirm) {
      Button("Reboot Comet", role: .destructive) { session.reboot() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This restarts the KVM appliance, not the attached computer. The session will reconnect when Comet is ready."
      )
    }
    .alert(
      "Trust This Comet’s Certificate?",
      isPresented: Binding(
        get: { session.pendingCertificate != nil },
        set: { if !$0 { session.pendingCertificate = nil } })
    ) {
      Button("Trust This Device") { session.approveCertificate() }
      Button("Cancel", role: .cancel) { session.pendingCertificate = nil }
    } message: {
      Text(
        "Verify this fingerprint for \(session.profile.host):\(session.profile.port) before continuing.\n\nSHA-256\n\(session.pendingCertificate ?? "")\n\nTrust applies only to this saved device and certificate."
      )
    }
    .sheet(isPresented: $diagnosticsOpen) { DiagnosticsView(session: session) }
    .sheet(
      isPresented: Binding(
        get: { session.ocrText != nil }, set: { if !$0 { session.ocrText = nil } })
    ) { OCRResultView(session: session) }
    .onAppear { model.selectedDevice = session.id }
  }

  // Show connection and capture state without permanent technical statistics.
  private var statusBar: some View {
    VStack(spacing: 0) {
      if let message = session.message {
        HStack {
          Image(systemName: "info.circle")
          Text(message).textSelection(.enabled)
          Spacer()
          Button {
            session.message = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain)
        }
        .font(.caption).padding(10).background(.regularMaterial)
      }
      HStack(spacing: 8) {
        Circle().fill(session.active ? Color.green : Color.secondary).frame(width: 6, height: 6)
        Text(session.phase.rawValue).accessibilityIdentifier("connection-status")
        Spacer()
        if let agent = model.agents[session.id] {
          AgentSessionControls(agent: agent)
        }
        if session.microphone {
          Label("Microphone forwarding", systemImage: "mic.fill").foregroundStyle(.orange)
        }
        if session.pasting {
          ProgressView().controlSize(.mini)
          Text("Typing clipboard…")
        } else if session.ocrBusy {
          ProgressView().controlSize(.mini)
          Text("Recognizing text on this Mac…")
        } else if session.ocrSelecting {
          Text("Drag to select text · Escape cancels")
        } else if session.captured {
          Text("Remote input · ⌃⌥⌘Esc to release").accessibilityIdentifier("capture-status")
        } else {
          Text("Click the display to capture input").accessibilityIdentifier("capture-status")
        }
        if session.profile.scaleMode == .fill {
          Text("Fill · image cropped").foregroundStyle(.orange)
        }
      }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 7)
        .background(.bar)
    }
  }
}

struct KeyboardPopover: View {
  @ObservedObject var session: SessionController

  // Explain target layout and capability-gated typing beside paste and remote shortcuts.
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Keyboard").font(.headline)
      Picker(
        "Target layout",
        selection: Binding(
          get: { session.profile.keymap },
          set: { value in session.updateProfile { $0.keymap = value } })
      ) {
        ForEach(session.state.availableKeymaps, id: \.self) { Text($0.uppercased()).tag($0) }
      }.disabled(!session.active)
      Text(
        "Choose the layout configured in the remote operating system. Your Mac’s layout resolves native typing."
      ).font(.caption).foregroundStyle(.secondary)
      Toggle(
        "Use Native Keyboard Layout",
        isOn: Binding(
          get: { session.profile.nativeLayout && session.state.mappedText },
          set: { value in session.updateProfile { $0.nativeLayout = value } })
      )
      .disabled(!session.state.mappedText).accessibilityIdentifier("native-layout-toggle")
      // Link the optional daemon patch beside its requirement so users can inspect native typing support.
      Text(
        "Requires the GLKVM Layout-Aware Typing daemon patch. Standard keyboard input and paste work without it. [See here](https://github.com/gl-inet/glkvm/pull/158)."
      ).font(.caption).foregroundStyle(.secondary)
      Toggle(
        "Enable Paste with ⌘V",
        isOn: Binding(
          get: { session.profile.pasteEnabled },
          set: { value in session.updateProfile { $0.pasteEnabled = value } }))
      Button("Paste Clipboard Text") { session.paste() }.disabled(
        !session.active || session.pasting)
      Text("Paste is sent once. Input already queued on the Comet may finish after disconnecting.")
        .font(.caption).foregroundStyle(.secondary)
      Divider()
      shortcut("Ctrl + Alt + Delete", keys: "⌃ ⌥ ⌦", codes: ["ControlLeft", "AltLeft", "Delete"])
      shortcut("Switch Windows", keys: "⌥ ⇥", codes: ["AltLeft", "Tab"])
      shortcut("Task Manager", keys: "⌃ ⇧ Esc", codes: ["ControlLeft", "ShiftLeft", "Escape"])
      shortcut("Windows / Super", keys: "⌘", codes: ["MetaLeft"])
      Text(
        "⌃⌥⌘Esc releases input. ⌃⌘F toggles fullscreen. Escape cancels unfinished native text; otherwise it goes to the remote computer."
      ).font(.caption).foregroundStyle(.secondary)
    }.padding(20).frame(width: 350)
  }

  // Send balanced remote shortcut transitions through the session’s ordered input queue.
  private func shortcut(_ title: String, keys: String, codes: [String]) -> some View {
    Button {
      session.shortcut(codes)
    } label: {
      HStack {
        Text(title)
        Spacer()
        Text(keys).font(.system(.body, design: .monospaced)).padding(.horizontal, 6).padding(
          .vertical, 3
        ).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
      }
    }.buttonStyle(.plain).disabled(!session.active)
  }
}

struct DisplayPopover: View {
  @ObservedObject var session: SessionController
  var openDisplaySettings: () -> Void

  // Separate local presentation from discovered device encoder controls.
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Text("Display").font(.headline)
        Picker(
          "Scaling",
          selection: Binding(
            get: { session.profile.scaleMode },
            set: { value in session.updateProfile { $0.scaleMode = value } })
        ) {
          ForEach(ScaleMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        Picker(
          "Rotation",
          selection: Binding(
            get: { session.profile.rotation },
            set: { value in session.updateProfile { $0.rotation = value } })
        ) {
          ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
        }
        Divider()
        // Link to the full device editor while keeping frequent local presentation controls compact.
        Button("Display Settings…", action: openDisplaySettings)
          .accessibilityIdentifier("display-settings-link")
        Divider()
        Text("Comet Video Encoder").font(.subheadline.bold())
        if session.state.params.isEmpty {
          // Missing encoder metadata does not imply that the authenticated video/input session is disconnected.
          Text(
            session.active
              ? "No encoder settings were reported by this Comet."
              : "Connect to discover video controls supported by this Comet."
          )
          .foregroundStyle(.secondary)
        } else {
          Menu("Quality Preset") {
            ForEach(VideoPreset.firmwarePresets) { preset in
              Button(preset.name) { session.setVideo(preset.parameters) }.disabled(
                !preset.supported(by: session.state))
            }
          }
          .accessibilityIdentifier("video-quality-presets")
          ForEach(
            [
              ("desired_fps", "Frame rate"), ("h264_bitrate", "Bitrate (kbps)"),
              ("h264_gop", "Keyframe interval"), ("quality", "JPEG quality"),
            ], id: \.0
          ) { key, title in
            if let value = session.state.params[key]?.number {
              numeric(key, title: title, value: value)
            }
          }
          let resolutions = session.state.streamer["limits"]["available_resolutions"].array
            .compactMap(\.string)
          if !resolutions.isEmpty {
            Picker("Encoder resolution", selection: parameter("resolution")) {
              ForEach(resolutions, id: \.self) { Text($0).tag($0) }
            }
          }
          if session.state.params["video_format"] != nil {
            Picker("Codec", selection: parameter("video_format")) {
              Text("H.264").tag("0")
              Text("H.265 · decoder unavailable").tag("1").disabled(true)
            }
          }
          if session.state.params["zero_delay"] != nil {
            Toggle(
              "Prefer low latency",
              isOn: Binding(
                get: { session.state.params["zero_delay"]?.bool ?? false },
                set: { session.setVideo(["zero_delay": String($0)]) }))
          }
          if session.state.params["venc_mode"] != nil {
            Picker("Encoder mode", selection: parameter("venc_mode")) {
              Text("Smart").tag("smart")
              Text("Normal").tag("normal")
            }
          }
          Text(
            "Transport: Native WebRTC. Direct-stream and FEC transport modes require a different media backend and are unavailable here."
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.padding(20)
    }.frame(width: 350, height: 480)
  }

  // Bind a device parameter to its synchronized state and scoped mutation endpoint.
  private func parameter(_ key: String) -> Binding<String> {
    Binding(get: { session.state.params[key]?.text ?? "" }, set: { session.setVideo([key: $0]) })
  }

  // Show editable numeric controls only with advertised bounds or a confirmed protocol contract.
  @ViewBuilder private func numeric(_ key: String, title: String, value: Double) -> some View {
    // GLKVM advertises quality support without bounds; its inspected validator defines the 1–100 contract.
    let qualitySupported =
      key == "quality" && session.state.streamer["features"]["quality"].bool == true
    let min = session.state.streamer["limits"][key]["min"].number ?? (qualitySupported ? 1 : nil)
    let max = session.state.streamer["limits"][key]["max"].number ?? (qualitySupported ? 100 : nil)
    if let min, let max, Int(exactly: min) != nil, Int(exactly: max) != nil, max > min {
      VStack(alignment: .leading) {
        HStack {
          Text(title)
          Spacer()
          Text(value.formatted(.number.precision(.fractionLength(0)))).monospacedDigit()
        }
        Slider(
          value: Binding(
            get: { Swift.min(max, Swift.max(min, session.state.params[key]?.number ?? value)) },
            set: {
              session.state.streamer = replacingParameter(key, value: $0)
              if let number = Int(exactly: $0) {
                session.setVideo([key: String(number)], debounce: true)
              }
            }), in: min...max, step: 1)
      }
    } else {
      LabeledContent(title, value: JSONValue.number(value).text)
    }
  }

  // Update the local slider preview while preserving all other streamed state fields.
  private func replacingParameter(_ key: String, value: Double) -> JSONValue {
    var root = session.state.streamer.object
    var params = root["params"]?.object ?? [:]
    params[key] = .number(value)
    root["params"] = .object(params)
    return .object(root)
  }
}

struct DiagnosticsView: View {
  @ObservedObject var session: SessionController
  @Environment(\.dismiss) private var dismiss

  // Present sampled transport and renderer measurements outside the primary remote display.
  var body: some View {
    Form {
      Text("Connection Diagnostics").font(.title2.bold())
      LabeledContent("Resolution", value: "\(session.metrics.width) × \(session.metrics.height)")
      LabeledContent(
        "Received / presented FPS",
        value: String(
          format: "%.1f / %.1f", session.metrics.receivedFPS, session.metrics.presentedFPS))
      LabeledContent(
        "Bitrate", value: String(format: "%.2f Mbps", session.metrics.bitrate / 1_000_000))
      LabeledContent(
        "Network RTT", value: String(format: "%.1f ms", session.metrics.rttMilliseconds))
      LabeledContent(
        "Last GPU duration", value: String(format: "%.2f ms", session.metrics.renderMilliseconds))
      LabeledContent("Decoder", value: session.metrics.decoder)
      LabeledContent("Received frames") {
        Text(String(session.metrics.received)).accessibilityIdentifier("diagnostic-received")
      }
      LabeledContent("Media connections started") {
        Text(String(session.mediaConnectionsStarted)).accessibilityIdentifier(
          "diagnostic-media-starts")
      }
      LabeledContent("Texture path", value: session.metrics.texturePath)
      LabeledContent(
        "Replaced / copied frames", value: "\(session.metrics.replaced) / \(session.metrics.copied)"
      )
      Text(
        "Queue: one newest frame, at most two GPU submissions. RTT and GPU duration are not end-to-end latency."
      ).font(.caption).foregroundStyle(.secondary)
      Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
    }.padding(24).frame(width: 560)
  }
}

struct OCRResultView: View {
  @ObservedObject var session: SessionController
  @Environment(\.dismiss) private var dismiss

  // Show selectable recognition output and discard it when the sheet closes.
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Recognized Text").font(.title2.bold())
      ScrollView {
        Text(
          session.ocrText?.isEmpty == false
            ? session.ocrText! : "No text found. Try selecting a larger or sharper area."
        ).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("ocr-result-text")
      }.frame(minHeight: 160)
      HStack {
        Text("Recognized locally on this Mac").font(.caption).foregroundStyle(.secondary)
        Spacer()
        // Cancel discards recognition without touching the clipboard; Escape follows the same path.
        Button("Cancel", role: .cancel) { close() }
          .keyboardShortcut(.cancelAction).accessibilityIdentifier("ocr-cancel")

        // Copy the complete result once and dismiss only after the clipboard accepts it.
        Button("Copy & Close") {
          guard let text = session.ocrText, !text.isEmpty else { return }
          NSPasteboard.general.clearContents()
          if NSPasteboard.general.setString(text, forType: .string) { close() }
        }
        .disabled(session.ocrText?.isEmpty != false)
        .keyboardShortcut(.defaultAction).accessibilityIdentifier("ocr-copy-close")
      }
    }.padding(24).frame(width: 540, height: 320)
  }

  // Clear the session's retained recognition before dismissing its native sheet.
  private func close() {
    session.ocrText = nil
    dismiss()
  }

}

// Keep Pause reachable beside the remote image even when the chat is behind another window.
private struct AgentSessionControls: View {
  @ObservedObject var agent: AgentController
  var body: some View {
    if agent.status.busy || agent.status == .paused {
      Text("Agent: " + agent.status.rawValue)
      Button(agent.status == .paused ? "Resume Agent" : "Pause Agent") {
        if agent.status == .paused { agent.resume() } else { agent.pause() }
      }.disabled(agent.status == .paused ? !agent.canResume : agent.status == .pausing)
        .accessibilityIdentifier("agent-session-pause")
    }
  }
}
