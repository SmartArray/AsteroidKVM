import AVFoundation
import Combine
import CometCore
import CometSessionCore
import UIKit

@MainActor final class MobileAppModel: ObservableObject {
  @Published var profiles: [ConnectionProfile] = []
  @Published var session: SessionCore?
  @Published var error: String?
  private let store = ProfileStore(
    url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AsteroidKVM/profiles.json"))
  private var suspended = false
  private let audio = MobileAudioSession()
  private var pendingInitialConnection: UUID?
  private var initialConnectionAllowed = false
  private var observers: [NSObjectProtocol] = []
  private var phaseObserver: AnyCancellable?
  init() {
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.environment["ASTEROID_UI_FIXTURE"] == "1" {
        session = makeUITestSession()
        return
      }
    #endif
    do { profiles = try store.load() } catch { self.error = error.localizedDescription }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        Task { @MainActor in
          if raw == AVAudioSession.InterruptionType.began.rawValue {
            self?.suspend()
          } else if UIApplication.shared.applicationState == .active {
            self?.resume()
          }
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] note in
        let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        if raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
          Task { @MainActor in self?.session?.updateProfile { $0.muted = true } }
        }
      })
  }
  func save(_ profile: ConnectionProfile, password: String? = nil) throws {
    var profile = profile
    if let previous = profiles.first(where: { $0.id == profile.id }) {
      profile = profile.securingReplacement(of: previous)
      // Only remove a credential that this saved connection could have persisted.
      // New and never-remembered connections must work without Keychain access.
      if previous.rememberPassword
        && (!profile.rememberPassword || previous.credentialAccount != profile.credentialAccount)
      {
        try PasswordStore().remove(for: previous)
      }
    }
    if profile.rememberPassword {
      if let password, !password.isEmpty { try PasswordStore().save(password, for: profile) }
    }
    var updated = profiles
    if let index = updated.firstIndex(where: { $0.id == profile.id }) {
      updated[index] = profile
    } else {
      updated.append(profile)
    }
    try store.save(updated)
    profiles = updated
  }
  func remove(_ profile: ConnectionProfile) {
    do {
      if profile.rememberPassword { try PasswordStore().remove(for: profile) }
      let updated = profiles.filter { $0.id != profile.id }
      try store.save(updated)
      profiles = updated
    } catch { self.error = error.localizedDescription }
  }
  func connect(_ profile: ConnectionProfile, password: String? = nil) {
    guard session == nil else { return }
    let created = SessionCore(profile: profile, password: password)
    created.onProfileChanged = { [weak self] profile in
      do { try self?.save(profile) } catch { self?.error = error.localizedDescription }
    }
    session = created
    pendingInitialConnection = created.id
    initialConnectionAllowed = false
    phaseObserver = created.$phase.sink { [weak created] phase in
      // Apply the saved mode only after the device advertises its switching endpoint.
      if phase == .connected, let created,
        let absolute = created.state.system["absolute_mouse"].bool,
        absolute != (created.profile.mobileMouseMode == .absolute)
      {
        Task { @MainActor [weak created] in
          guard let created, created.active else { return }
          created.setSystemParameter(
            "absolute_mouse", value: String(created.profile.mobileMouseMode == .absolute))
        }
      }
      UIApplication.shared.isIdleTimerDisabled =
        phase == .connected && UIApplication.shared.applicationState == .active
    }
  }
  // The session view calls this only after the first-use cover has finished dismissing.
  func startPendingConnection() async {
    guard let created = session, pendingInitialConnection == created.id else { return }
    initialConnectionAllowed = true
    guard !suspended else { return }
    do { try await audio.activate() } catch { self.error = error.localizedDescription }
    guard session === created, pendingInitialConnection == created.id, !suspended else { return }
    pendingInitialConnection = nil
    created.connect()
  }
  func close() async {
    guard let closing = session else { return }
    await closing.disconnect()
    closing.typingDraft = ""
    try? await audio.deactivate()
    session = nil
    pendingInitialConnection = nil
    initialConnectionAllowed = false
    suspended = false
    phaseObserver = nil
    UIApplication.shared.isIdleTimerDisabled = false
  }
  func suspend() {
    guard !suspended, session != nil else { return }
    suspended = true
    session?.suspend()
    UIApplication.shared.isIdleTimerDisabled = false
  }
  func resume() {
    guard suspended else { return }
    suspended = false
    if pendingInitialConnection != nil {
      guard initialConnectionAllowed else { return }
      Task { await startPendingConnection() }
      return
    }
    let resuming = session
    Task {
      do { try await audio.activate() } catch { self.error = error.localizedDescription }
      guard let resuming, session === resuming, !suspended else { return }
      resuming.wake()
    }
  }
}

@MainActor final class ConnectionTestController: ObservableObject {
  enum Status: Equatable {
    case idle, testing, success
    case failure(String)
  }
  @Published private(set) var status: Status = .idle
  @Published private(set) var approvalRequired = false
  @Published var pendingCertificate: String?
  private var task: Task<Void, Never>?
  private var api: CometAPI?
  private var generation = UUID()

  func reset() {
    generation = UUID()
    task?.cancel()
    task = nil
    api?.transport.session.invalidateAndCancel()
    api = nil
    status = .idle
    approvalRequired = false
    pendingCertificate = nil
  }

  func test(profile: ConnectionProfile, password: String) {
    reset()
    let ticket = generation
    status = .testing
    task = Task {
      guard ticket == generation, !Task.isCancelled else { return }
      let api = CometAPI(profile: profile)
      self.api = api
      var signedIn = false
      var result = Status.success
      var certificate: String?
      do {
        guard profile.baseURL != nil, !profile.username.isEmpty else {
          throw CometError.invalidAddress
        }
        let secret =
          try password.isEmpty
          ? (profile.rememberPassword ? PasswordStore().password(for: profile) : nil) : password
        guard let secret, !secret.isEmpty else {
          throw CometError.unsupported("Enter a password to test this connection.")
        }
        try await api.login(password: secret) { [weak self] in
          await self?.showApprovalRequired(ticket: ticket)
        }
        signedIn = true
        _ = try await api.discover()
        try Task.checkCancellation()
      } catch {
        result = .failure(error.localizedDescription)
        if case CometError.certificate(let fingerprint) = error { certificate = fingerprint }
      }
      // This temporary sign-in never opens media or sends remote input.
      if signedIn && !Task.isCancelled { try? await api.logout() }
      await api.close()
      guard ticket == generation, !Task.isCancelled else { return }
      self.api = nil
      task = nil
      approvalRequired = false
      status = result
      pendingCertificate = certificate
      UINotificationFeedbackGenerator().notificationOccurred(result == .success ? .success : .error)
    }
  }

  private func showApprovalRequired(ticket: UUID) {
    guard generation == ticket else { return }
    approvalRequired = true
  }
}

// Audio route activation can block; keep it off the UI actor and serialize route changes.
private actor MobileAudioSession {
  func activate() throws {
    try AVAudioSession.sharedInstance().setCategory(
      .playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
    try AVAudioSession.sharedInstance().setActive(true)
  }
  func deactivate() throws {
    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
