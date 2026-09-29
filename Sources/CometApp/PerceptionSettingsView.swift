import CometCore
import CometSession
import SwiftUI

struct PerceptionSettingsView: View {
  @ObservedObject private var service = LocalPerception.shared
  @State private var draft = PerceptionSettings()
  @State private var token = ""
  @State private var error: String?
  @State private var checking = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        "Parse KVM screens locally. All connections share the parser; each device keeps its own element IDs and cache."
      )
      Toggle("Enable local UI parsing", isOn: $draft.enabled).accessibilityIdentifier(
        "perception-enable")
      TextField("Service host", text: $draft.host)
      SecureField("Service token (leave blank to keep saved token)", text: $token)
      TextField("Service port", value: $draft.port, format: .number.grouping(.never))
      Picker("Preferred inference device", selection: $draft.preferredDevice) {
        Text("Automatic (prefer MPS)").tag("auto")
        Text("Apple GPU / MPS").tag("mps")
        Text("CPU").tag("cpu")
      }
      Text(
        "Models load once at startup. Save your preference, then stop and start the service to change CPU/MPS selection. CPU fallback is reported below."
      )
      .font(.caption).foregroundStyle(.secondary)
      Stepper(
        "Request timeout: \(Int(draft.requestTimeout)) seconds", value: $draft.requestTimeout,
        in: 1...110)
      VStack(alignment: .leading) {
        Text("Cache change threshold: \(draft.cacheThreshold * 100, specifier: "%.1f")% per tile")
        Slider(value: $draft.cacheThreshold, in: 0...0.05, step: 0.001)
        Text(
          "Lower values reparse more often. Element actions always use a stricter threshold of at most 1% changed pixels per tile."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading) {
        Text("Minimum detection confidence: \(draft.minimumConfidence, specifier: "%.2f")")
        Slider(value: $draft.minimumConfidence, in: 0...1, step: 0.01)
      }
      Stepper(
        "Settle after focusing a text field: \(draft.settlingMilliseconds) ms",
        value: $draft.settlingMilliseconds, in: 0...2000, step: 50)
      Toggle("Log performance diagnostics", isOn: $draft.debugLogging)
      Text(
        "Performance logs contain timings, cache status and device selection, never screenshots or detected text."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button("Save and Check Connection") {
          do {
            try service.save(
              draft, token: token.isEmpty ? nil : token)
            token = ""
            error = nil
            checking = true
            Task {
              await service.checkHealth()
              checking = false
            }
          } catch { self.error = error.localizedDescription }
        }.disabled(checking)
        Button("Reconnect") {
          checking = true
          Task {
            await service.checkHealth()
            checking = false
          }
        }.disabled(checking || !service.settings.enabled)
        if checking { ProgressView().controlSize(.small) }
      }
      Text(service.status).textSelection(.enabled)
      if let health = service.health {
        LabeledContent("Model", value: health.model)
        LabeledContent("Version", value: health.version ?? "Not loaded")
        LabeledContent("CPU fallback", value: health.cpuFallback ? "Active" : "No")
      }
      if let error { Text(error).foregroundStyle(.red) }
      Text(
        "Start the local parser service before checking the connection. Raw screenshots and keyboard/mouse tools remain available if parsing is disabled."
      )
      .font(.caption).foregroundStyle(.secondary)
    }.onAppear { draft = service.settings }
  }
}
