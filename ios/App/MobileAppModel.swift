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
      if previous.credentialAccount != profile.credentialAccount {
        try PasswordStore().remove(for: previous)
      }
    }
    if profile.rememberPassword {
      if let password, !password.isEmpty { try PasswordStore().save(password, for: profile) }
    } else {
      try PasswordStore().remove(for: profile)
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
      try PasswordStore().remove(for: profile)
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
    Task {
      do { try await audio.activate() } catch { self.error = error.localizedDescription }
      guard session === created, !suspended else { return }
      pendingInitialConnection = nil
      created.connect()
    }
  }
  func close() async {
    guard let closing = session else { return }
    await closing.disconnect()
    closing.typingDraft = ""
    try? await audio.deactivate()
    session = nil
    pendingInitialConnection = nil
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
    let resuming = session
    Task {
      do { try await audio.activate() } catch { self.error = error.localizedDescription }
      guard let resuming, session === resuming, !suspended else { return }
      if pendingInitialConnection == resuming.id {
        pendingInitialConnection = nil
        resuming.connect()
      } else {
        resuming.wake()
      }
    }
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
