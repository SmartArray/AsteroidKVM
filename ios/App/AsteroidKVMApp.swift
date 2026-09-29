import CometCore
import SwiftUI

@main struct AsteroidKVMApp: App {
  @StateObject private var model = MobileAppModel()
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("appearance") private var appearance = "System"
  var body: some Scene {
    WindowGroup {
      Group {
        if let session = model.session {
          MobileSessionView(session: session)
        } else {
          ConnectionsView()
        }
      }
      .environmentObject(model)
      .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { model.resume() } else { model.suspend() }
      }
      .alert(
        "AsteroidKVM",
        isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
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
    }
  }
  private func add() { editing = ConnectionProfile(name: "", host: "") }
}

struct ProfileEditor: View {
  @EnvironmentObject var model: MobileAppModel
  @Environment(\.dismiss) private var dismiss
  @State var profile: ConnectionProfile
  @State private var password = ""
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("Connection") {
          TextField("Name", text: $profile.name).accessibilityIdentifier("connection-name")
          TextField("Hostname or IP address", text: $profile.host).keyboardType(.URL)
            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier(
              "connection-host")
          Picker("Protocol", selection: $profile.scheme) {
            Text("HTTPS").tag("https")
            Text("HTTP").tag("http")
          }
          .onChange(of: profile.scheme) { old, new in
            if profile.port == (old == "https" ? 443 : 80) {
              profile.port = new == "https" ? 443 : 80
            }
          }
          TextField("Port", value: $profile.port, format: .number.grouping(.never)).keyboardType(
            .numberPad)
        }
        Section("Authentication") {
          TextField("Username", text: $profile.username).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("Password", text: $password).textContentType(.password)
          Toggle("Remember password in Keychain", isOn: $profile.rememberPassword)
          if profile.certificateSHA256 != nil {
            Button("Reset certificate trust", role: .destructive) {
              profile.certificateSHA256 = nil
            }
          }
          Text("Certificate exceptions require explicit approval when connecting.").font(.caption)
            .foregroundStyle(.secondary)
        }
        if let error { Text(error).foregroundStyle(.red) }
      }
      .navigationTitle("Connection")
      .toolbar {
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
