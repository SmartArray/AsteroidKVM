// Present per-Comet EDID drafts while keeping device identity, HDMI modes, and local scaling distinct.
import CometCore
import CometSession
import SwiftUI

struct DisplaySettingsView: View {
  @ObservedObject var session: SessionController
  @ObservedObject var settings: DisplaySettingsController

  // Observe the session-owned controller so reopening Settings retains an unapplied draft.
  init(session: SessionController) {
    self.session = session
    settings = session.displaySettings
  }

  // Device reads happen on opening or reconnect; selecting a profile never uploads it implicitly.
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(session.profile.name).font(.headline)
      LabeledContent(
        "Comet model", value: settings.model.isEmpty ? "Unknown" : settings.model.uppercased())
      LabeledContent("Received video", value: receivedResolution)
        .accessibilityIdentifier("display-received-resolution")
      LabeledContent(
        "Current EDID preference",
        value: settings.current?.preferredMode ?? "Factory default / unavailable")
      if let identity = settings.current?.identity {
        LabeledContent(
          "Current identity",
          value: "\(identity.manufacturer) · \(String(format: "0x%04X", identity.product))")
      }

      // Profiles supply complete timings and audio; identity fields below remain independently editable.
      GroupBox("EDID") {
        VStack(alignment: .leading, spacing: 12) {
          Picker(
            "Target resolution (preferred)",
            selection: Binding(
              get: { matchingPreset },
              set: { value in
                if let preset = EDIDPreset(rawValue: value) { settings.select(preset) }
              })
          ) {
            Text("Current / custom timing").tag("")
            ForEach(EDIDPreset.allCases) { preset in
              Text(preset.label).tag(preset.rawValue).disabled(!settings.presets.contains(preset))
            }
          }.accessibilityIdentifier("display-target-resolution")
          Text(
            "A resolution profile replaces the timing template and includes HDMI audio. The target computer decides whether to use the preferred mode."
          )
          .font(.caption).foregroundStyle(.secondary)
          if settings.presets.isEmpty {
            Text("Resolution profiles are unavailable until a supported Comet model is identified.")
              .font(.caption).foregroundStyle(.secondary)
          }

          // String bindings allow partial edits; validation prevents out-of-range values reaching the device.
          Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            identityRow(
              "Manufacturer ID", value: $settings.manufacturer, identifier: "edid-manufacturer")
            identityRow("Product code (hex)", value: $settings.product, identifier: "edid-product")
            identityRow("Serial number (hex)", value: $settings.serial, identifier: "edid-serial")
            identityRow("Manufacture week", value: $settings.week, identifier: "edid-week")
            identityRow("Manufacture year", value: $settings.year, identifier: "edid-year")
          }.disabled(settings.draft == nil)
          Button("Use Example Identity") { settings.useExampleIdentity() }
            .disabled(settings.draft == nil).accessibilityIdentifier("edid-example")
          Text(
            "Example: DEL / 0xA034 / 0x3031304C · week 12, 2020. Illustrative identity, not a verified Dell monitor profile. Week 0 means unspecified; 255 preserves an EDID 1.4 model year."
          )
          .font(.caption).foregroundStyle(.secondary)
          if settings.draft != nil, let error = settings.validationMessage {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("edid-validation")
          }
        }.padding(8)
      }.disabled(!session.active || !settings.isCurrent || settings.busy)

      // Explicit Apply and Restore operations are the only controls that alter the appliance.
      HStack {
        Button("Discard Changes / Reload") { Task { await settings.reload() } }
          .disabled(!session.active || settings.busy).accessibilityIdentifier("edid-reload")
        Spacer()
        Button("Restore Previous EDID") { Task { await settings.restore() } }
          .disabled(
            !session.active || !settings.canRestore
          )
          .accessibilityIdentifier("edid-restore")
        Button("Apply") { Task { await settings.apply() } }
          .buttonStyle(.borderedProminent).disabled(!session.active || !settings.canApply)
          .accessibilityIdentifier("edid-apply")
      }
      Text(
        "Applying EDID may briefly interrupt HDMI video. The target may need a display-settings adjustment or restart; Asteroid does not restart it."
      )
      .font(.caption).foregroundStyle(.secondary)
      if settings.loaded && settings.current == nil {
        Text(
          "The firmware has not exposed its factory EDID bytes. Exact restoration of this default is unavailable."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if settings.busy { ProgressView().controlSize(.small) }
      if let message = settings.message {
        Text(message).textSelection(.enabled).accessibilityIdentifier("edid-status")
      }
      if !session.active {
        Text("Connect this Comet to configure its display.").foregroundStyle(.secondary)
      }
    }
    .task(
      id:
        "\(session.active)|\(session.profile.baseURL?.absoluteString ?? "")|\(session.profile.certificateSHA256 ?? "")"
    ) {
      if session.active && !settings.isCurrent { await settings.reload() }
    }
  }

  // Match the complete timing template, not its identity, when showing the selected bundled resolution.
  private var matchingPreset: String {
    guard let draft = settings.draft else { return "" }
    return EDIDPreset.allCases.first {
      guard let template = try? $0.document(identity: draft.identity) else { return false }
      return template == draft
    }?.rawValue ?? ""
  }

  // Report actual decoded pixels without implying that a stored EDID preference has been adopted by the OS.
  private var receivedResolution: String {
    guard session.active, session.state.online != false, session.mailbox.frameAge < 2,
      let frame = session.mailbox.snapshot()
    else { return "No live HDMI video" }
    return "\(Int(frame.size.width)) × \(Int(frame.size.height))"
  }

  // Keep stable accessibility identifiers on individual editable controls for native UI verification.
  private func identityRow(_ title: String, value: Binding<String>, identifier: String) -> some View
  {
    GridRow {
      Text(title)
      TextField(title, text: value).labelsHidden().textFieldStyle(.roundedBorder)
        .accessibilityIdentifier(identifier)
    }
  }
}
