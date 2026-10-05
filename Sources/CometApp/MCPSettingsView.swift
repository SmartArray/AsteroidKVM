import CometCore
import CometSession
import SwiftUI

// Keep everyday setup and control visible; disclose connection maintenance separately.
struct MCPSettingsView: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var session: SessionController
  @ObservedObject var server: DeviceMCPServer
  @State private var port = ""
  @State private var advancedExpanded = false
  @State private var activityExpanded = false
  @State private var confirmTokenReset = false
  @State private var copied = false
  @State private var copyError: String?

  private var enabled: Bool { session.profile.mcp?.enabled == true }
  private var allowsControl: Bool { session.profile.mcp?.allowControl == true }
  private var listening: Bool { enabled && server.status == "Listening" }
  private var selectedPort: Int { session.profile.mcp?.port ?? 9101 }
  private var validatedPort: Int? {
    guard let value = Int(port.trimmingCharacters(in: .whitespaces)),
      (1024...65535).contains(value) else { return nil }
    return value
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      serverCard
      if enabled {
        setupCard
        controlCard
        clientsCard
        activityCard
      }
      advancedCard
    }
    .onAppear { port = String(selectedPort) }
    .onChange(of: selectedPort) { _, value in port = String(value); clearCopyFeedback() }
    .onChange(of: enabled) { _, _ in clearCopyFeedback() }
    .onChange(of: server.status) { _, _ in clearCopyFeedback() }
    .alert("Replace this device’s access token?", isPresented: $confirmTokenReset) {
      Button("Replace Token", role: .destructive) {
        clearCopyFeedback()
        server.regenerateToken()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Connected MCP clients will be disconnected. Copy the new configuration into each client to reconnect.")
    }
  }

  private var serverCard: some View {
    card {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "network")
          .font(.title2).foregroundStyle(.tint)
          .frame(width: 36, height: 36)
          .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        VStack(alignment: .leading, spacing: 5) {
          Text("MCP server").font(.headline)
          Text("Let an AI client access \(session.profile.name) through AsteroidKVM.")
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Toggle(enabled ? "Server enabled" : "Start MCP server",
          isOn: Binding(get: { enabled }, set: setEnabled))
          .toggleStyle(.switch).fixedSize()
          .accessibilityIdentifier("mcp-enable")
      }
      Divider()
      HStack(spacing: 6) {
        Circle().fill(statusColor).frame(width: 7, height: 7)
        Text(statusTitle).font(.callout.weight(.medium))
          .accessibilityIdentifier("mcp-server-status")
        Spacer()
        Label("Only on this Mac", systemImage: "lock.shield")
          .font(.caption).foregroundStyle(.secondary)
      }
      if enabled && !listening && server.status != "Starting…" {
        Text(server.status).font(.callout).foregroundStyle(.orange)
          .textSelection(.enabled).accessibilityIdentifier("mcp-server-error")
      } else if !enabled {
        Text("Turn on Start MCP server to begin listening immediately. Then copy the configuration into your client. No port setup is needed.")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  private var setupCard: some View {
    card {
      Label("Connect your client", systemImage: "link").font(.headline)
      Text("Copy this device’s configuration into your client’s MCP settings. Keep AsteroidKVM running while you use it.")
        .font(.callout).foregroundStyle(.secondary)
      HStack(spacing: 10) {
        Text(server.endpoint).font(.system(.callout, design: .monospaced))
          .textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.8)
          .accessibilityIdentifier("mcp-endpoint")
        Spacer(minLength: 0)
        Button(action: copyConfiguration) {
          Label(copied ? "Copied" : "Copy Configuration", systemImage: copied ? "checkmark" : "doc.on.doc")
        }.buttonStyle(.borderedProminent).disabled(!listening)
          .accessibilityIdentifier("mcp-copy-configuration")
      }
      Text(copied ? "Configuration copied with this device’s access token." : "Includes the server address and access token.")
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityIdentifier("mcp-copy-feedback")
      if let copyError {
        Label(copyError, systemImage: "exclamationmark.circle")
          .font(.callout).foregroundStyle(.red)
      }
      if !session.active {
        Divider()
        HStack(alignment: .center, spacing: 12) {
          Label("Connect the remote device to use screen and input tools.", systemImage: "desktopcomputer")
            .font(.callout).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button("Open Connection") {
            openWindow(value: session.id)
            session.connect()
          }.accessibilityIdentifier("mcp-open-connection")
        }
      }
    }
  }

  private var controlCard: some View {
    card {
      Label("Client permissions", systemImage: "hand.raised").font(.headline)
      Picker("Client access", selection: Binding(
        get: { allowsControl }, set: { value in update { $0.allowControl = value } }
      )) {
        Text("View only").tag(false)
        Text("Keyboard & mouse").tag(true)
      }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("mcp-access")
      Text(allowsControl
        ? "Clients can inspect the screen, type, click, and scroll. Your input pauses MCP control unless you select Lock for MCP in the remote window’s status bar."
        : "Clients can inspect the screen and read text. Keyboard and mouse actions are blocked.")
        .font(.callout).foregroundStyle(.secondary)
      if allowsControl {
        Divider()
        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 5) {
            Label(server.paused ? "Control paused" : "Control allowed",
              systemImage: server.paused ? "pause.circle.fill" : "cursorarrow.rays")
              .font(.callout.weight(.medium))
              .foregroundStyle(server.paused ? Color.orange : Color.primary)
              .accessibilityIdentifier("mcp-control-status")
            Text(controlDescription).font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          if server.paused {
            Button("Resume Control") {
              session.releaseCapture()
              server.resumeControl()
            }.disabled(!listening).accessibilityIdentifier("mcp-resume")
          } else {
            Button("Pause Control") {
              server.pauseControl()
              session.interruptAutomation()
              session.releaseCapture()
            }.disabled(!listening).accessibilityIdentifier("mcp-stop")
          }
        }
        Text("Emergency stop: ⌃⌥⌘Esc while AsteroidKVM is active, including when manual input is locked.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var clientsCard: some View {
    card {
      HStack {
        Label("Connected clients", systemImage: "person.2").font(.headline)
        Spacer()
        Text("\(server.clients.count)").font(.caption.monospacedDigit())
          .padding(.horizontal, 8).padding(.vertical, 3)
          .background(.quaternary, in: Capsule())
      }
      if server.clients.isEmpty {
        Text("No clients connected yet. Add the configuration to your client to get started.")
          .font(.callout).foregroundStyle(.secondary)
          .accessibilityIdentifier("mcp-clients-empty")
      } else {
        ForEach(Array(server.clients.enumerated()), id: \.offset) { _, name in
          Label(name, systemImage: "desktopcomputer").font(.callout)
        }
      }
    }
  }

  private var activityCard: some View {
    card {
      disclosureHeader("Recent activity", icon: "clock", expanded: $activityExpanded,
        identifier: "mcp-activity")
      if activityExpanded {
        VStack(alignment: .leading, spacing: 12) {
          Text("Recent requests are kept in memory. Typed text and screenshots are never included.")
            .font(.caption).foregroundStyle(.secondary)
          if server.history.isEmpty {
            Text("No requests yet.").font(.callout).foregroundStyle(.secondary)
          }
          ForEach(server.history.prefix(20)) { item in
            VStack(alignment: .leading, spacing: 4) {
              HStack(alignment: .firstTextBaseline) {
                Text(item.tool).font(.system(.callout, design: .monospaced))
                  .textSelection(.enabled)
                Spacer()
                Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
              }
              Text("\(item.client) · \(item.outcome)")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
          }
        }.padding(.top, 10)
      }
    }
  }

  private var advancedCard: some View {
    card {
      disclosureHeader("Advanced", icon: "slider.horizontal.3", expanded: $advancedExpanded,
        identifier: "mcp-advanced")
      if advancedExpanded {
        VStack(alignment: .leading, spacing: 14) {
          Text("Connection").font(.subheadline.weight(.semibold))
          HStack {
            Text("Local port")
            TextField("Port", text: $port)
              .textFieldStyle(.roundedBorder).frame(width: 90)
              .onSubmit(applyPort).accessibilityIdentifier("mcp-port")
            Button("Apply", action: applyPort)
              .disabled(validatedPort == nil || validatedPort == selectedPort)
              .accessibilityIdentifier("mcp-apply-port")
            Spacer()
          }
          if validatedPort == nil {
            Text("Enter a port from 1024 to 65535.")
              .font(.caption).foregroundStyle(.red).accessibilityIdentifier("mcp-port-error")
          } else {
            Text("Each device needs a different port. After changing it, copy the updated configuration into your client.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Divider()
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text("Access token").font(.subheadline.weight(.semibold))
              Text("Stored securely in Keychain for this device.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Replace Token…") { confirmTokenReset = true }
              .disabled(!enabled).accessibilityIdentifier("mcp-replace-token")
          }
          Text("Replacing the token disconnects clients and invalidates their saved configuration.")
            .font(.caption).foregroundStyle(.secondary)
          Divider()
          Text("Idle clients disconnect after 5 minutes. Input ownership expires after 30 idle seconds; individual operations time out after 2 minutes.")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 12)
      }
    }
  }

  private var statusTitle: String {
    if !enabled { return "Off" }
    if listening { return "Ready for clients" }
    if server.status == "Starting…" { return "Starting…" }
    return "Needs attention"
  }

  private var statusColor: Color {
    if !enabled { return .secondary }
    return listening ? .green : .orange
  }

  private var controlDescription: String {
    switch server.pauseReason {
    case .manualInput: return "You took over with the keyboard or mouse. Resume when you’re ready."
    case .stopRequested: return "You paused automation. Screen inspection is still available."
    case .interrupted: return "Automation was interrupted. Resume to allow new input actions."
    case nil: return "Pause at any time without disconnecting your clients."
    }
  }

  private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12, content: content)
      .frame(maxWidth: .infinity, alignment: .leading).padding(16)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary).allowsHitTesting(false))
  }

  // Make the entire disclosure row clickable and keyboard-accessible, not just a small triangle.
  private func disclosureHeader(
    _ title: String, icon: String, expanded: Binding<Bool>, identifier: String
  ) -> some View {
    Button {
      withAnimation(.easeInOut(duration: 0.15)) { expanded.wrappedValue.toggle() }
    } label: {
      HStack {
        Label(title, systemImage: icon).font(.headline)
        Spacer()
        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
      }.contentShape(Rectangle())
    }.buttonStyle(.plain)
      .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
      .accessibilityIdentifier(identifier)
  }

  private func update(_ change: (inout MCPPreferences) -> Void) {
    session.updateProfile {
      var preferences = $0.mcp ?? MCPPreferences()
      change(&preferences)
      $0.mcp = preferences
    }
  }

  private func setEnabled(_ value: Bool) {
    var nextPort = selectedPort
    if value, session.profile.mcp == nil {
      let used = Set(model.sessions.values.filter {
        $0.id != session.id && $0.profile.mcp?.enabled == true
      }.compactMap { $0.profile.mcp?.port })
      while used.contains(nextPort), nextPort < 65535 { nextPort += 1 }
    }
    update { $0.enabled = value; $0.port = nextPort }
    port = String(nextPort)
  }

  private func applyPort() {
    guard let value = validatedPort, value != selectedPort else { return }
    update { $0.port = value }
  }

  private func clearCopyFeedback() {
    copied = false
    copyError = nil
  }

  private func copyConfiguration() {
    do {
      let configuration = try server.configuration()
      NSPasteboard.general.clearContents()
      guard NSPasteboard.general.setString(configuration, forType: .string) else {
        copyError = "Could not copy the configuration. Try again."
        copied = false
        return
      }
      copied = true
      copyError = nil
    } catch {
      copied = false
      copyError = error.localizedDescription
    }
  }
}
