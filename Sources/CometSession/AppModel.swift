// Own saved profiles and coordinate focus across otherwise independent sessions.
import AppKit
import Combine
import CometCore
import CometMedia

@MainActor public final class AppModel: ObservableObject {
  @Published public var profiles: [ConnectionProfile] = []
  @Published public var sessions: [UUID: SessionController] = [:]
  @Published public var error: String?
  @Published public var selectedDevice: UUID?
  private let store: ProfileStore
  private let mediaFactory: @MainActor (CometAPI, FrameMailbox) -> any MediaConnection
  private var observers: [NSObjectProtocol] = []
  public var launchSessionID: UUID?
  public let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")

  // UI tests use an isolated store; normal sessions never import the hardware test file implicitly.
  public init(
    profileStoreURL: URL? = nil,
    mediaFactory: @escaping @MainActor (CometAPI, FrameMailbox) -> any MediaConnection = {
      JanusClient(api: $0, mailbox: $1)
    }
  ) {
    self.mediaFactory = mediaFactory
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    let path =
      testing
      ? FileManager.default.temporaryDirectory.appendingPathComponent(
        "CometKVM-UITests/profiles.json") : support.appendingPathComponent("CometKVM/profiles.json")
    store = ProfileStore(url: profileStoreURL ?? path)
    do { profiles = testing ? [] : try store.load() } catch {
      self.error = error.localizedDescription
    }
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in Task { @MainActor in self?.sessions.values.forEach { $0.suspend() } }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in Task { @MainActor in self?.sessions.values.forEach { $0.wake() } }
      })
    importExplicitSession()
  }

  // Persist only profile preferences and explicitly remembered Keychain credentials.
  public func save(_ profile: ConnectionProfile, password: String?) throws {
    guard profile.baseURL != nil else { throw CometError.invalidAddress }
    if profile.rememberPassword, let password, !password.isEmpty {
      try PasswordStore().save(password, for: profile)
    }
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
    try store.save(profiles)
  }

  // Disconnect the selected session before removing its saved profile; password removal stays explicit.
  public func remove(_ profile: ConnectionProfile) async {
    await sessions[profile.id]?.disconnect()
    sessions.removeValue(forKey: profile.id)
    profiles.removeAll { $0.id == profile.id }
    do { try store.save(profiles) } catch { self.error = error.localizedDescription }
  }

  // Reuse an existing session or instantiate one from the selected saved profile.
  public func session(for id: UUID) -> SessionController? {
    if let existing = sessions[id] { return existing }
    guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
    return createSession(profile: profile)
  }

  // Create isolated session ownership and connect its focus and preference callbacks to the registry.
  @discardableResult public func createSession(
    profile: ConnectionProfile, password: String? = nil, token: String? = nil
  ) -> SessionController {
    let session = SessionController(
      profile: profile, password: password, token: token, mediaFactory: mediaFactory)
    session.onCapture = { [weak self] focused in
      for (id, session) in self?.sessions ?? [:] where id != focused { session.releaseCapture() }
      self?.selectedDevice = focused
    }
    session.onProfileChanged = { [weak self] profile in
      guard let self, profiles.contains(where: { $0.id == profile.id }) else { return }
      do { try save(profile, password: nil) } catch { self.error = error.localizedDescription }
    }
    sessions[profile.id] = session
    selectedDevice = profile.id
    return session
  }

  // An explicit command-line session is ephemeral and useful for repeatable real-device E2E runs.
  private func importExplicitSession() {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--session-file"), args.indices.contains(index + 1) else {
      return
    }
    do {
      let data = try Data(
        contentsOf: URL(fileURLWithPath: NSString(string: args[index + 1]).expandingTildeInPath))
      let json = try JSONValue.decode(data)
      let raw = json["host"].text
      guard let url = URL(string: raw.contains("://") ? raw : "https://" + raw), let host = url.host
      else { throw CometError.invalidAddress }
      var profile = ConnectionProfile(
        name: "Comet Test Session", host: host, port: url.port ?? (url.scheme == "http" ? 80 : 443),
        scheme: url.scheme ?? "https", username: json["username"].text)
      profile.keymap = json["keymap"].string ?? "en-us"
      let session = createSession(profile: profile, token: json["token"].string)
      launchSessionID = session.id
    } catch { self.error = error.localizedDescription }
  }
}
