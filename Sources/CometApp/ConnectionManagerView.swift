import CometCore
import CometSession
// Present saved connections with native list editing and a focused profile sheet.
import SwiftUI

struct ConnectionManagerView: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @State private var selected: UUID?
  @State private var editing: ConnectionProfile?
  @State private var adding = false
  @State private var removal: ConnectionProfile?

  // Present saved profiles with native editing and independently opened remote windows.
  var body: some View {
    VStack(spacing: 0) {
      if model.profiles.isEmpty {
        ContentUnavailableView {
          Label("Your remote machines", systemImage: "desktopcomputer")
        } description: {
          Text("Add a Comet to connect securely to its remote display.")
        } actions: {
          Button("Add Connection…") { adding = true }.buttonStyle(.borderedProminent)
            .accessibilityIdentifier("add-connection")
        }
      } else {
        List(selection: $selected) {
          ForEach(model.profiles) { profile in
            HStack(spacing: 12) {
              Image(systemName: "desktopcomputer").font(.title2).foregroundStyle(.tint)
              VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.headline)
                Text(profile.host).foregroundStyle(.secondary).font(.caption)
              }
              Spacer()
              if let session = model.sessions[profile.id] {
                Text(session.phase.rawValue).font(.caption).foregroundStyle(.secondary)
              }
              Button("Connect") { connect(profile) }.accessibilityIdentifier(
                "connect-\(profile.name)")
            }
            .padding(.vertical, 6).tag(profile.id)
            .contextMenu {
              Button("Open Connection") { connect(profile) }
              Button("Edit…") { editing = profile }
              Button("Disconnect") { Task { await model.sessions[profile.id]?.disconnect() } }
              Divider()
              Button("Remove…", role: .destructive) { removal = profile }
            }
          }
        }
      }
      Divider()
      HStack {
        Button {
          adding = true
        } label: {
          Image(systemName: "plus")
        }.help("Add Connection").accessibilityIdentifier("add-connection-toolbar")
        Button {
          editing = model.profiles.first { $0.id == selected }
        } label: {
          Image(systemName: "pencil")
        }.disabled(selected == nil).help("Edit Connection")
        Button {
          removal = model.profiles.first { $0.id == selected }
        } label: {
          Image(systemName: "minus")
        }.disabled(selected == nil).help("Remove Connection")
        Spacer()
        Text("AsteroidKVM").font(.caption).foregroundStyle(.secondary)
      }.padding(12)
    }
    .frame(minWidth: 520, minHeight: 340)
    .sheet(isPresented: $adding) { ProfileEditor(profile: ConnectionProfile(name: "", host: "")) }
    .sheet(item: $editing) { profile in ProfileEditor(profile: profile) }
    .alert(
      "Remove Connection?",
      isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    ) {
      Button("Remove", role: .destructive) {
        if let removal { Task { await model.remove(removal) } }
        removal = nil
      }
      Button("Cancel", role: .cancel) { removal = nil }
    } message: {
      Text(
        "The saved connection will be removed. Saved passwords can be removed separately in Settings → Connections."
      )
    }
    .task {
      if let id = model.launchSessionID {
        model.launchSessionID = nil
        openWindow(value: id)
        model.sessions[id]?.connect()
      }
    }
    .overlay(alignment: .bottom) {
      if let error = model.error { Text(error).foregroundStyle(.red).padding() }
    }
  }

  // Open or establish the selected session using its own profile and credentials.
  private func connect(_ profile: ConnectionProfile) {
    let session = model.session(for: profile.id)
    openWindow(value: profile.id)
    session?.connect()
  }
}

struct ProfileEditor: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State var profile: ConnectionProfile
  @State private var password = ""
  @State private var error: String?

  // Collect one profile and optional session password without placing secrets in persisted JSON.
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(profile.name.isEmpty ? "Add Connection" : "Edit Connection").font(.title2.bold())
      Form {
        TextField("Name", text: $profile.name).accessibilityIdentifier("profile-name")
        TextField("Hostname or IP", text: $profile.host).accessibilityIdentifier("profile-host")
        Picker("Connection", selection: $profile.scheme) {
          Text("HTTPS").tag("https")
          Text("HTTP").tag("http")
        }
        TextField("Port", value: $profile.port, format: .number.grouping(.never))
          .accessibilityIdentifier("profile-port")
        TextField("Username", text: $profile.username)
        SecureField("Password", text: $password).accessibilityIdentifier("profile-password")
        Toggle("Remember password in Keychain", isOn: $profile.rememberPassword)
        if profile.scheme == "http" {
          Text("HTTP sends credentials without encryption. Use it only on a trusted network.").font(
            .caption
          ).foregroundStyle(.secondary)
        }
      }
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          Task {
            do {
              try model.save(profile, password: password)
              if let existing = model.sessions[profile.id] {
                await existing.replaceProfile(profile, password: password)
              } else if !password.isEmpty {
                model.createSession(profile: profile, password: password)
              }
              password = ""
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
        }.keyboardShortcut(.defaultAction).disabled(
          profile.name.trimmingCharacters(in: .whitespaces).isEmpty || profile.baseURL == nil)
      }
    }.padding(24).frame(width: 420)
  }
}
