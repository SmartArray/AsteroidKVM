// Own saved profiles and coordinate focus across otherwise independent sessions.
import AppKit
import Combine
import CometAgent
import CometCore
import CometMedia

@MainActor public final class AppModel: ObservableObject {
  @Published public var profiles: [ConnectionProfile] = []
  @Published public var sessions: [UUID: SessionController] = [:]
  @Published public private(set) var agents: [UUID: AgentController] = [:]
  @Published public var error: String?
  // Share Settings navigation so toolbar shortcuts can select a section in an already open window.
  @Published public var settingsSection = "General"
  @Published public var selectedDevice: UUID?
  private let store: ProfileStore
  private let mediaFactory: @MainActor (CometAPI, FrameMailbox) -> any MediaConnection
  private var observers: [NSObjectProtocol] = []
  public var launchSessionID: UUID?
  public let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")

  // UI tests use an isolated store; production sessions migrate saved data to the renamed app namespace.
  public init(
    profileStoreURL: URL? = nil,
    mediaFactory: @escaping @MainActor (CometAPI, FrameMailbox) -> any MediaConnection = {
      JanusClient(api: $0, mailbox: $1)
    }
  ) {
    self.mediaFactory = mediaFactory
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    let path = testing
      ? FileManager.default.temporaryDirectory.appendingPathComponent(
        "AsteroidKVM-UITests/profiles.json")
      : support.appendingPathComponent("AsteroidKVM/profiles.json")
    let legacyPath = support.appendingPathComponent("CometKVM/profiles.json")
    var migrationError: Error?
    if !testing, profileStoreURL == nil {
      do {
        try ProfileStore.migrateIfNeeded(from: legacyPath, to: path)
        Self.migratePreferences()
      } catch { migrationError = error }
    }
    store = ProfileStore(url: profileStoreURL ?? path)
    if let migrationError { self.error = migrationError.localizedDescription }
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
    for profile in profiles where profile.mcp?.enabled == true { _ = session(for: profile.id) }
  }

  // Copy only this app's named preferences so the new bundle identifier keeps the user's local choices.
  private static func migratePreferences() {
    guard let legacy = UserDefaults(suiteName: "app.cometkvm.CometKVM") else { return }
    let current = UserDefaults.standard
    for key in [
      "appearance", "agentClickPreviewsEnabled", "agentCodexPath", "agentModel", "agentThinkingLevel",
    ] where current.object(forKey: key) == nil {
      if let value = legacy.object(forKey: key) { current.set(value, forKey: key) }
    }
  }

  // Persist only profile preferences and explicitly remembered Keychain credentials.
  public func save(_ profile: ConnectionProfile, password: String?) throws {
    // Sanitize the persisted copy independently of live sessions so endpoint edits cannot migrate trust.
    let profile =
      profiles.first(where: { $0.id == profile.id }).map {
        profile.securingReplacement(of: $0)
      } ?? profile
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
    sessions[profile.id]?.mcpServer.disable()
    agents.removeValue(forKey: profile.id)?.stop()
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
    // App-audio capture cannot separate two WebRTC playbacks; close transcription before any new media starts.
    session.onMediaStarting = { [weak self] in
      self?.sessions.values.forEach {
        if $0.transcription.active {
          $0.transcription.stop(reason: "Stopped because a remote connection started or reconnected")
        }
      }
    }
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
    session.mcpServer.configure()
    return session
  }

  // Gate app-audio capture to one remote session and retrieve the provider key only on explicit activation.
  public func setTranscription(_ enabled: Bool, for session: SessionController) {
    guard enabled else { session.transcription.stop(); return }
    guard session.active else {
      session.transcription.stop(reason: "Connect the remote display before transcribing")
      return
    }
    guard !session.profile.muted else {
      session.transcription.stop(reason: "Turn off Mute remote playback in Devices settings before transcribing")
      return
    }
    guard !sessions.values.contains(where: {
      $0.id != session.id && $0.phase != .disconnected && $0.phase != .authenticating
    }) else {
      session.transcription.stop(reason: "Disconnect other remote sessions before transcribing")
      return
    }
    do {
      let key = try TranscriptionCredentials.read() ?? ""
      session.transcription.start(key: key,
        language: UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "")
    } catch {
      session.transcription.stop(reason: "Could not read the OpenAI API key from Keychain")
    }
  }

  // Keep one conversation per remote connection and pause it before manual input or lifecycle changes.
  public func agent(for session: SessionController) -> AgentController {
    if let agent = agents[session.id] { return agent }
    let agent = AgentController(computer: SessionAgentComputer(session: session))
    // New conversations inherit the saved model; changing one chat must not interrupt another connection's agent.
    agent.selectModel(UserDefaults.standard.string(forKey: "agentModel") ?? "")
    agent.selectThinkingLevel(UserDefaults.standard.string(forKey: "agentThinkingLevel") ?? "")
    session.onAgentInterruption = { [weak agent] in
      agent?.pause(reason: "Paused for manual input or a connection change.")
    }
    // Identity changes destroy provider context and permissions, including completed idle conversations.
    session.onAgentIdentityChanged = { [weak agent] in agent?.resetTarget() }
    agents[session.id] = agent
    return agent
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
