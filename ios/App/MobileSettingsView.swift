import CometCore
import CometMedia
import CometSessionCore
import SwiftUI

struct MobileSettingsView: View {
  @ObservedObject var session: SessionCore
  var fit: () -> Void
  var guide: () -> Void
  @Environment(\.dismiss) private var dismiss
  @AppStorage("appearance") private var appearance = "System"
  @AppStorage("keyboardToolbarEnabled") private var keyboardToolbarEnabled = true
  @State private var confirmation: DeviceChange?
  @State private var about = false
  private struct DeviceChange: Identifiable {
    let id = UUID()
    var title: String
    var action: () -> Void
  }
  private func preference<T>(_ path: WritableKeyPath<ConnectionProfile, T>) -> Binding<T> {
    Binding(
      get: { session.profile[keyPath: path] },
      set: { value in session.updateProfile { $0[keyPath: path] = value } })
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("View") {
          Button("Fit to Screen", action: fit)
          Picker("Rotation", selection: preference(\.rotation)) {
            ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
          }
          Picker("Appearance", selection: $appearance) {
            ForEach(["System", "Light", "Dark"], id: \.self) { Text($0).tag($0) }
          }
        }
        Section("Mouse") {
          Picker(
            "Mouse mode",
            selection: Binding(
              get: { session.profile.mobileMouseMode },
              set: { value in
                session.updateProfile { $0.mobileMouseMode = value }
                if session.state.system["absolute_mouse"].bool != nil {
                  session.setSystemParameter("absolute_mouse", value: String(value == .absolute))
                }
              })
          ) { ForEach(MobileMouseMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
          Toggle("Send mouse input", isOn: preference(\.mouseEnabled))
          Text("Trackpad sensitivity")
          Slider(value: preference(\.mouseSensitivity), in: 0.1...4)
          Text("Scroll sensitivity")
          Slider(value: preference(\.scrollSensitivity), in: 0.1...4)
          Toggle("Reverse scrolling", isOn: preference(\.reverseScrolling))
          Text("Use three fingers to scroll. Position the pointer over the desired panel first.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("Keyboard & Type") {
          Toggle("Show special-key toolbar", isOn: $keyboardToolbarEnabled)
            .accessibilityIdentifier("keyboard-toolbar-setting")
          Text("Swipe the toolbar for more keys. Tap modifiers to apply them to the next key.")
            .font(.caption).foregroundStyle(.secondary)
          Toggle("Send keyboard input", isOn: preference(\.keyboardEnabled))
          Toggle("Use native keyboard layout", isOn: preference(\.nativeLayout)).disabled(
            !session.state.mappedText)
          if !session.state.availableKeymaps.isEmpty {
            Picker("Target keymap", selection: preference(\.keymap)) {
              ForEach(session.state.availableKeymaps, id: \.self) { Text($0).tag($0) }
            }
          }
          Stepper(
            "Mapped-key interval: \(session.profile.nativeTypingIntervalMilliseconds) ms",
            value: preference(\.nativeTypingIntervalMilliseconds), in: 0...1000, step: 10)
          Button("Reset interval to 50 ms") {
            session.updateProfile { $0.nativeTypingIntervalMilliseconds = 50 }
          }
          Text(
            "This interval applies to mapped external-keyboard input. Type uses the KVM’s slow print API; its rate is controlled by firmware."
          ).font(.caption).foregroundStyle(.secondary)
        }
        Section("Screen quality") {
          ForEach(VideoPreset.firmwarePresets) { preset in
            Button(preset.name) { session.setVideo(preset.parameters) }.disabled(
              !session.active || !preset.supported(by: session.state))
          }
          ForEach(
            [
              ("desired_fps", "Frame rate"), ("h264_bitrate", "H.264 bitrate (kbps)"),
              ("h264_gop", "Keyframe interval"), ("quality", "JPEG quality"),
            ], id: \.0
          ) { key, title in
            if let current = session.state.params[key]?.number,
              let low = session.state.streamer["limits"][key]["min"].number
                ?? (key == "quality" && session.state.streamer["features"]["quality"].bool == true
                  ? 1 : nil),
              let high = session.state.streamer["limits"][key]["max"].number
                ?? (key == "quality" && session.state.streamer["features"]["quality"].bool == true
                  ? 100 : nil),
              low < high, Int(exactly: low) != nil, Int(exactly: high) != nil
            {
              VideoSlider(title: title, value: current, range: low...high) {
                session.setVideo([key: String(Int($0))], debounce: true)
              }
            }
          }
          let resolutions = session.state.streamer["limits"]["available_resolutions"].array
            .compactMap(\.string)
          if session.state.params["resolution"] != nil && !resolutions.isEmpty {
            Picker(
              "Stream resolution",
              selection: Binding(
                get: { session.state.params["resolution"]?.text ?? "" },
                set: { session.setVideo(["resolution": $0]) })
            ) { ForEach(resolutions, id: \.self) { Text($0).tag($0) } }
          }
          if session.state.params["zero_delay"] != nil {
            Toggle(
              "Prefer low latency",
              isOn: Binding(
                get: { session.state.params["zero_delay"]?.bool ?? false },
                set: { session.setVideo(["zero_delay": String($0)]) }))
          }
          if session.state.params["video_format"] != nil {
            Picker(
              "Codec",
              selection: Binding(
                get: { session.state.params["video_format"]?.text ?? "0" },
                set: { session.setVideo(["video_format": $0]) })
            ) {
              Text("H.264").tag("0")
              Text("H.265 · decoder unavailable").tag("1").disabled(true)
            }
          }
          if session.state.params["venc_mode"] != nil {
            Picker(
              "Encoder mode",
              selection: Binding(
                get: { session.state.params["venc_mode"]?.text ?? "normal" },
                set: { session.setVideo(["venc_mode": $0]) })
            ) {
              Text("Smart").tag("smart")
              Text("Normal").tag("normal")
            }
          }
          if session.state.params.isEmpty {
            Text("Quality controls are unavailable until the KVM advertises encoder settings.")
              .foregroundStyle(.secondary)
          }
          NavigationLink("Display / EDID") {
            MobileDisplaySettings(session: session, settings: session.displaySettings)
          }
        }
        Section("Audio") {
          Toggle("Mute remote audio", isOn: preference(\.muted))
          Toggle(
            "Forward microphone",
            isOn: Binding(get: { session.microphone }, set: { session.setMicrophone($0) })
          ).disabled(!session.active || session.mediaFeatures["mic"].bool != true)
          if session.mediaFeatures["mic"].bool != true {
            Text("Microphone forwarding is not advertised by this media service.").font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        deviceSection
        Section("Text recognition") {
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
          }
          Text("Recognition runs locally on a frozen video frame.").font(.caption).foregroundStyle(
            .secondary)
        }
        Section("Connection") {
          LabeledContent("Host", value: session.profile.host)
          LabeledContent("Status", value: session.phase.rawValue)
          LabeledContent(
            "Decoded size", value: "\(session.metrics.width) × \(session.metrics.height)")
          LabeledContent(
            "Frames per second", value: String(format: "%.1f", session.metrics.receivedFPS))
          LabeledContent(
            "Round trip", value: String(format: "%.0f ms", session.metrics.rttMilliseconds))
          if session.active {
            Button("Restart KVM", role: .destructive) {
              confirmation = DeviceChange(
                title: "Restart the KVM? The connection will be interrupted.",
                action: { session.reboot() })
            }
          }
        }
        Section {
          Button("Gesture Guide", action: guide)
          Button("About") { about = true }
        }
      }
      .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .confirmationDialog(
        confirmation?.title ?? "Confirm change",
        isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
        titleVisibility: .visible
      ) {
        Button("Apply", role: .destructive) {
          confirmation?.action()
          confirmation = nil
        }
        Button("Cancel", role: .cancel) { confirmation = nil }
      }
      .sheet(isPresented: $about) { AboutView() }
    }
  }
  private var deviceSection: some View {
    Section("KVM devices") {
      ForEach(
        [
          ("enable_keyboard", "USB keyboard"), ("enable_mouse", "USB mouse"),
          ("enable_mouse_alt", "Alternate USB mouse"), ("start_cdrom", "Virtual CD-ROM"),
          ("start_flash", "Virtual flash drive"), ("enable_mic", "USB microphone"),
          ("enable_audio", "USB audio"), ("enable_speaker", "USB speaker"),
          ("enable_camera", "USB camera"), ("enable_mtp", "Media transfer (MTP)"),
        ], id: \.0
      ) { key, title in
        if let current = session.state.functions[key].bool {
          Toggle(
            title,
            isOn: Binding(
              get: { current },
              set: { value in
                confirmation = DeviceChange(
                  title: "Change \(title)? USB devices may reconnect.",
                  action: { session.setDevice(key, value: value) })
              })
          ).disabled(!session.active)
        }
      }
      ForEach(
        [
          ("keyboard", "Keyboard output", "keyboard_output"),
          ("mouse", "Mouse output", "mouse_output"),
        ], id: \.0
      ) { key, title, parameter in
        let options = session.state.hid[key]["outputs"]["available"].array.compactMap(\.string)
        if !options.isEmpty {
          Picker(
            title,
            selection: Binding(
              get: { session.state.hid[key]["outputs"]["active"].text },
              set: { value in
                confirmation = DeviceChange(
                  title: "Change \(title)? Remote input may be interrupted.",
                  action: { session.setHID(parameter, value: value) })
              })
          ) { ForEach(options, id: \.self) { Text($0).tag($0) } }
        }
      }
      if session.state.hid["jiggler"]["enabled"].bool == true {
        Toggle(
          "Mouse jiggler",
          isOn: Binding(
            get: { session.state.hid["jiggler"]["active"].bool ?? false },
            set: { session.setHID("jiggler", value: String($0)) }))
        JigglerSettingsView(session: session)
      }
      if session.state.functions == .null {
        Text("USB function controls are unavailable on this firmware.").font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct VideoSlider: View {
  let title: String
  let value: Double
  let range: ClosedRange<Double>
  var apply: (Double) -> Void
  @State private var draft = 0.0
  var body: some View {
    VStack(alignment: .leading) {
      Text("\(title): \(Int(draft))")
      Slider(value: $draft, in: range, step: 1) { editing in if !editing { apply(draft) } }
    }.onAppear { draft = min(range.upperBound, max(range.lowerBound, value)) }
      .onChange(of: value) { _, value in draft = min(range.upperBound, max(range.lowerBound, value))
      }
  }
}

struct MobileDisplaySettings: View {
  @ObservedObject var session: SessionCore
  @ObservedObject var settings: DisplaySettingsController
  @State private var apply = false
  @State private var restore = false
  var body: some View {
    Form {
      Section("Connected display") {
        LabeledContent("KVM model", value: settings.model.isEmpty ? "Unknown" : settings.model)
        LabeledContent("Preferred mode", value: settings.current?.preferredMode ?? "Unavailable")
        if let message = settings.message { Text(message).foregroundStyle(.secondary) }
        if settings.busy { ProgressView() }
        Button("Reload") { Task { await settings.reload() } }.disabled(
          !session.active || settings.busy)
      }
      Section("Resolution profile") {
        ForEach(settings.presets) { preset in Button(preset.label) { settings.select(preset) } }
        if settings.presets.isEmpty { Text("No supported resolution profiles are advertised.") }
        Text("Selected: \(settings.draft?.preferredMode ?? "Current")")
      }.disabled(!settings.isCurrent || settings.busy)
      Section("Monitor identity") {
        TextField("Manufacturer ID", text: $settings.manufacturer)
        TextField("Product code (hex)", text: $settings.product)
        TextField("Serial number (hex)", text: $settings.serial)
        TextField("Manufacture week", text: $settings.week).keyboardType(.numberPad)
        TextField("Manufacture year", text: $settings.year).keyboardType(.numberPad)
        if let error = settings.validationMessage { Text(error).foregroundStyle(.red) }
      }.textInputAutocapitalization(.never).autocorrectionDisabled().disabled(
        settings.draft == nil || settings.busy)
      Section {
        Button("Apply display settings") { apply = true }.disabled(
          !session.active || !settings.canApply)
        Button("Restore previous EDID") { restore = true }.disabled(
          !session.active || !settings.canRestore)
        Text(
          "Changing EDID can interrupt HDMI video. The target computer chooses its display mode. The previous EDID is backed up locally when available."
        ).font(.caption).foregroundStyle(.secondary)
      }
    }.navigationTitle("Display / EDID")
      .task(id: session.active) {
        if session.active && !settings.isCurrent { await settings.reload() }
      }
      .confirmationDialog(
        "Apply EDID and reconnect the display?", isPresented: $apply, titleVisibility: .visible
      ) { Button("Apply", role: .destructive) { Task { await settings.apply() } } }
      .confirmationDialog(
        "Restore the saved EDID?", isPresented: $restore, titleVisibility: .visible
      ) { Button("Restore", role: .destructive) { Task { await settings.restore() } } }
  }
}

struct AboutView: View {
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("AsteroidKVM").font(.largeTitle.bold())
          Text("A native remote console for iPhone and iPad.")
          Text("Version 1.0 · iOS 17 or later").foregroundStyle(.secondary)
          Text("Third-party notices").font(.headline)
          Text(notices).font(.caption).textSelection(.enabled)
        }.padding()
      }.navigationTitle("About").toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
  }
  private var notices: String {
    guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else {
      return "Notices unavailable."
    }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? "Notices unavailable."
  }
}
