import CometCore
import SwiftUI

@main struct AsteroidKVMApp: App {
  @StateObject private var model = MobileAppModel()
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("appearance") private var appearance = "System"
  @AppStorage("welcomeVersion") private var welcomeVersion = 0
  init() {
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.environment["ASTEROID_RESET_WELCOME"] == "1" {
        UserDefaults.standard.removeObject(forKey: "welcomeVersion")
      }
      if ProcessInfo.processInfo.environment["ASTEROID_RESET_KEYBOARD_TOOLBAR"] == "1" {
        UserDefaults.standard.removeObject(forKey: "keyboardToolbarEnabled")
      }
    #endif
  }
  var body: some Scene {
    WindowGroup {
      Group {
        if welcomeVersion < 1 {
          AppOnboardingView { welcomeVersion = 1 }
        } else if let session = model.session {
          MobileSessionView(session: session).id(session.id)
        } else {
          ConnectionsView()
        }
      }
      .environmentObject(model)
      .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
      .onChange(of: scenePhase) { _, phase in
        model.sceneChanged(phase)
      }
      .alert(
        "AsteroidKVM",
        isPresented: Binding(
          get: { welcomeVersion >= 1 && model.error != nil }, set: { if !$0 { model.error = nil } })
      ) {
        Button("OK") { model.error = nil }
      } message: {
        Text(model.error ?? "")
      }
    }
  }
}

struct ConnectionsView: View {
  @EnvironmentObject var model: MobileAppModel
  @State private var editing: ConnectionProfile?
  @State private var authentication: ConnectionProfile?
  @AppStorage("onboardingVersion") private var onboardingVersion = 0
  @State private var showGuide = false
  @State private var showAbout = false
  @State private var showWelcome = false
  var body: some View {
    NavigationStack {
      List {
        if model.profiles.isEmpty {
          ContentUnavailableView(
            "Add your first KVM", systemImage: "desktopcomputer",
            description: Text("Add your KVM’s hostname or IP address to get started."))
          Button("Add connection", systemImage: "plus") { add() }.accessibilityIdentifier(
            "add-first-connection")
        }
        ForEach(model.profiles) { profile in
          Button {
            if profile.rememberPassword { model.connect(profile) } else { authentication = profile }
          } label: {
            HStack(spacing: 16) {
              Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.tint)
              VStack(alignment: .leading) {
                Text(profile.name).font(.headline).foregroundStyle(.primary)
                Text(profile.host).font(.subheadline).foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }.padding(.vertical, 8)
          }
          .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { model.remove(profile) }
            Button("Edit") { editing = profile }.tint(.blue)
          }
          .contextMenu { Button("Edit connection") { editing = profile } }
        }
      }
      .navigationTitle("Connections")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Add connection", systemImage: "plus") { add() }
        }
        ToolbarItem(placement: .topBarLeading) {
          Menu("More", systemImage: "ellipsis.circle") {
            Button("Welcome tour", systemImage: "sparkles") { showWelcome = true }
            Button("Gesture Guide", systemImage: "hand.draw") { showGuide = true }
            Button("About", systemImage: "info.circle") { showAbout = true }
          }
        }
      }
      .sheet(item: $editing) { ProfileEditor(profile: $0) }
      .sheet(item: $authentication) { PasswordSheet(profile: $0) }
      .sheet(isPresented: $showGuide) {
        GestureOnboardingView {
          onboardingVersion = 1
          showGuide = false
        }
      }
      .sheet(isPresented: $showAbout) { AboutView() }
      .fullScreenCover(isPresented: $showWelcome) {
        AppOnboardingView { showWelcome = false }
      }
    }
  }
  private func add() { editing = ConnectionProfile(name: "", host: "") }
}

struct ProfileEditor: View {
  private enum Field: Hashable { case name, host, port, username, password }
  @EnvironmentObject var model: MobileAppModel
  @Environment(\.dismiss) private var dismiss
  @State var profile: ConnectionProfile
  @State private var password = ""
  @State private var error: String?
  @StateObject private var connectionTest = ConnectionTestController()
  @FocusState private var focusedField: Field?
  var body: some View {
    NavigationStack {
      Form {
        Section("Connection") {
          TextField("Name", text: $profile.name).accessibilityIdentifier("connection-name")
            .focused($focusedField, equals: .name)
          TextField("Hostname or IP address", text: $profile.host).keyboardType(.URL)
            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(
              "connection-host"
            )
            .focused($focusedField, equals: .host)
          Picker("Protocol", selection: $profile.scheme) {
            Text("HTTPS").tag("https")
            Text("HTTP").tag("http")
          }.accessibilityIdentifier("connection-protocol")
            .onChange(of: profile.scheme) { old, new in
              if profile.port == (old == "https" ? 443 : 80) {
                profile.port = new == "https" ? 443 : 80
              }
            }
          TextField("Port", value: $profile.port, format: .number.grouping(.never)).keyboardType(
            .numberPad
          ).accessibilityIdentifier("connection-port")
            .focused($focusedField, equals: .port)
        }
        Section("Authentication") {
          TextField("Username", text: $profile.username).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focusedField, equals: .username)
          SecureField("Password", text: $password).textContentType(.password)
            .accessibilityIdentifier("connection-password")
            .focused($focusedField, equals: .password)
          Toggle("Remember password in Keychain", isOn: $profile.rememberPassword)
          if profile.certificateSHA256 != nil {
            Button("Reset certificate trust", role: .destructive) {
              profile.certificateSHA256 = nil
              connectionTest.reset()
            }
          }
          Text("Certificate exceptions require explicit approval when connecting.").font(.caption)
            .foregroundStyle(.secondary)
        }
        if let error { Text(error).foregroundStyle(.red) }
        Section {
          Button {
            focusedField = nil
            connectionTest.test(profile: profile, password: password)
          } label: {
            HStack {
              if connectionTest.status == .testing { ProgressView() }
              Label(testTitle, systemImage: testSymbol)
              Spacer()
            }.foregroundStyle(testColor)
          }
          .accessibilityIdentifier("test-connection")
          .disabled(
            connectionTest.status == .testing || profile.baseURL == nil || profile.username.isEmpty)
          if connectionTest.status == .testing {
            if connectionTest.approvalRequired {
              Text("Approve this sign-in on the KVM’s screen.").font(.callout)
            }
            Button("Cancel test") { connectionTest.reset() }
          }
          if case .failure(let message) = connectionTest.status {
            Text(message).font(.callout).foregroundStyle(.red)
              .accessibilityIdentifier("connection-test-error")
          }
        } footer: {
          Text(
            "Checks sign-in and access to the KVM. Test video and remote controls after connecting."
          )
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("Connection")
      .toolbar {
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") { focusedField = nil }.accessibilityIdentifier("editor-done-typing")
        }
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            do {
              try model.save(profile, password: password)
              dismiss()
            } catch { self.error = error.localizedDescription }
          }.disabled(
            profile.baseURL == nil
              || profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || profile.username.isEmpty)
        }
      }
      .onChange(of: profile.credentialAccount) { _, _ in
        profile.certificateSHA256 = nil
        connectionTest.reset()
      }
      .onChange(of: profile.rememberPassword) { _, _ in connectionTest.reset() }
      .onChange(of: password) { _, _ in connectionTest.reset() }
      .onDisappear { connectionTest.reset() }
      .alert(
        "Trust this KVM certificate?",
        isPresented: Binding(
          get: { connectionTest.pendingCertificate != nil },
          set: { if !$0 { connectionTest.pendingCertificate = nil } }),
        presenting: connectionTest.pendingCertificate
      ) { fingerprint in
        Button("Cancel", role: .cancel) { connectionTest.pendingCertificate = nil }
        Button("Trust and test") {
          profile.certificateSHA256 = fingerprint
          connectionTest.test(profile: profile, password: password)
        }
      } message: { fingerprint in
        Text(
          "Verify this SHA-256 fingerprint against your KVM before approving:\n\n\(fingerprint)"
        )
      }
    }
  }
  private var testTitle: String {
    switch connectionTest.status {
    case .idle: return "Test connection"
    case .testing: return "Testing connection…"
    case .success: return "Connection successful"
    case .failure: return "Connection failed — try again"
    }
  }
  private var testSymbol: String {
    switch connectionTest.status {
    case .success: return "checkmark.circle.fill"
    case .failure: return "xmark.circle.fill"
    default: return "network"
    }
  }
  private var testColor: Color {
    switch connectionTest.status {
    case .success: return .green
    case .failure: return .red
    default: return .accentColor
    }
  }
}

struct PasswordSheet: View {
  @EnvironmentObject var model: MobileAppModel
  @Environment(\.dismiss) private var dismiss
  let profile: ConnectionProfile
  @State private var password = ""
  var body: some View {
    NavigationStack {
      Form {
        Section(profile.name) {
          SecureField("Password", text: $password).textContentType(.password)
        }
      }
      .navigationTitle("Connect")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Connect") {
            dismiss()
            model.connect(profile, password: password)
          }.disabled(password.isEmpty)
        }
      }
    }.presentationDetents([.medium])
  }
}
