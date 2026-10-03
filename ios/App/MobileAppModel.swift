import AVFoundation
import Combine
import CometCore
import CometMedia
import CometSessionCore
import CoreImage
import CryptoKit
import SwiftUI
import UIKit

@MainActor final class MobileAppModel: ObservableObject {
  @Published var profiles: [ConnectionProfile] = []
  @Published var session: SessionCore?
  @Published var error: String?
  @Published private(set) var previews: [UUID: UIImage] = [:]
  @Published private(set) var switchingProfile: ConnectionProfile?
  @Published private(set) var previewToken = UUID()
  var switchingConnection: Bool { switchingProfile != nil }
  private var passwords: [String: String] = [:]
  private let previewStore = ConnectionPreviewStore()
  private let store = ProfileStore(
    url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AsteroidKVM/profiles.json"))
  private var suspended = false
  private let audio = MobileAudioSession()
  @Published private var pendingInitialConnection: UUID?
  var startingConnection: Bool { session != nil && pendingInitialConnection == session?.id }
  private var initialConnectionAllowed = false
  private var observers: [NSObjectProtocol] = []
  private var phaseObserver: AnyCancellable?
  init() {
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.environment["ASTEROID_UI_FIXTURE"] == "1" {
        let first = ConnectionProfile(name: "Simulator fixture", host: "fixture.invalid")
        profiles = [
          first, ConnectionProfile(name: "Studio Mac", host: "studio.invalid"),
          ConnectionProfile(name: "Home server", host: "server.invalid"),
        ]
        for index in profiles.indices {
          profiles[index].id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!
        }
        session = makeUITestSession(profile: profiles[0])
        loadPreviews()
        return
      }
    #endif
    do { profiles = try store.load() } catch { self.error = error.localizedDescription }
    loadPreviews()
    observers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        Task { @MainActor in
          if raw == AVAudioSession.InterruptionType.began.rawValue {
            // An audio interruption can happen while video is still visible.
            self?.session?.releaseCapture()
          } else if UIApplication.shared.applicationState == .active, self?.session != nil {
            try? await self?.audio.activate()
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
  private func loadPreviews() {
    Task {
      for profile in profiles {
        if let data = await previewStore.load(profile),
          profiles.contains(where: {
            $0.id == profile.id && $0.credentialAccount == profile.credentialAccount
          }), previews[profile.id] == nil
        {
          previews[profile.id] = UIImage(data: data)
        }
      }
    }
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
      if previous.credentialAccount != profile.credentialAccount {
        passwords[previous.credentialAccount] = nil
        previews[profile.id] = nil
        Task { await previewStore.remove(previous) }
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
    if let password, !password.isEmpty, passwords[profile.credentialAccount] != nil {
      passwords[profile.credentialAccount] = password
    }
  }
  func remove(_ profile: ConnectionProfile) {
    do {
      if profile.rememberPassword { try PasswordStore().remove(for: profile) }
      let updated = profiles.filter { $0.id != profile.id }
      try store.save(updated)
      profiles = updated
      passwords[profile.credentialAccount] = nil
      previews[profile.id] = nil
      Task { await previewStore.remove(profile) }
    } catch { self.error = error.localizedDescription }
  }
  func connect(_ profile: ConnectionProfile, password: String? = nil) {
    guard session == nil else { return }
    previewToken = UUID()
    if let password, !password.isEmpty { passwords[profile.credentialAccount] = password }
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.environment["ASTEROID_UI_FIXTURE"] == "1" {
        let created = makeUITestSession(profile: profile)
        session = created
        simulateUITestReconnect(created)
        return
      }
    #endif
    let created = SessionCore(profile: profile, password: passwords[profile.credentialAccount])
    created.onProfileChanged = { [weak self] profile in
      do { try self?.save(profile) } catch { self?.error = error.localizedDescription }
    }
    session = created
    pendingInitialConnection = created.id
    initialConnectionAllowed = false
    phaseObserver = created.$phase.removeDuplicates().sink { [weak created] phase in
      // Reapply the saved gesture mode to the live HID output after every connection.
      // The system startup preference can disagree with the running USB mouse.
      if phase == .connected || phase == .noSignal {
        Task { @MainActor [weak created] in
          guard let created, created.active else { return }
          created.synchronizeMobileMouseMode()
        }
      }
      UIApplication.shared.isIdleTimerDisabled =
        phase == .connected && UIApplication.shared.applicationState == .active
    }
  }
  func authenticate(_ session: SessionCore, password: String) {
    guard self.session === session else { return }
    passwords[session.profile.credentialAccount] = password
    session.connect(password: password)
  }

  func capturePreview(_ source: SessionCore, frame: VideoFrame? = nil) async {
    guard let frame = frame ?? source.mailbox.snapshot() else { return }
    let profile = source.profile
    let data = await previewStore.capture(frame, profile: profile)
    guard
      profiles.contains(where: {
        $0.id == profile.id && $0.credentialAccount == profile.credentialAccount
      }),
      let data
    else { return }
    previews[profile.id] = UIImage(data: data)
  }

  func switchConnection(to profile: ConnectionProfile) async {
    guard !switchingConnection, let previous = session, previous.id != profile.id,
      profiles.contains(where: { $0.id == profile.id })
    else { return }
    switchingProfile = profile
    defer { switchingProfile = nil }
    await capturePreview(previous)
    phaseObserver = nil
    await previous.disconnect()
    session = nil
    pendingInitialConnection = nil
    initialConnectionAllowed = false
    connect(profile)
    // The new view's first-use gate starts the connection after any onboarding.
  }

  func sceneChanged(_ phase: ScenePhase) {
    switch phase {
    case .active:
      resume()
      UIApplication.shared.isIdleTimerDisabled = session?.active == true
    case .inactive:
      session?.releaseCapture()
      UIApplication.shared.isIdleTimerDisabled = false
    case .background:
      // Retain the frame synchronously, before stopping the decoder clears its mailbox.
      if let session, let frame = session.mailbox.snapshot() {
        Task { await capturePreview(session, frame: frame) }
      }
      suspend()
    @unknown default: break
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
    guard !switchingConnection, let closing = session else { return }
    await capturePreview(closing)
    await closing.disconnect()
    closing.typingDraft = ""
    try? await audio.deactivate()
    session = nil
    pendingInitialConnection = nil
    initialConnectionAllowed = false
    suspended = false
    phaseObserver = nil
    passwords.removeAll()
    UIApplication.shared.isIdleTimerDisabled = false
  }
  func suspend() {
    guard !suspended, session != nil else { return }
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.environment["ASTEROID_UI_FIXTURE"] == "1" {
        UITestInputRecorder.suspensions += 1
      }
    #endif
    suspended = true
    previewToken = UUID()
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
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.environment["ASTEROID_UI_FIXTURE"] == "1",
        let resuming
      {
        simulateUITestReconnect(resuming)
        return
      }
    #endif
    Task {
      do { try await audio.activate() } catch { self.error = error.localizedDescription }
      guard let resuming, session === resuming, !suspended else { return }
      resuming.wake()
    }
  }
}

// Small local previews survive relaunches; rendering and disk access stay off the UI actor.
private actor ConnectionPreviewStore {
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("ConnectionPreviews", isDirectory: true)

  private func url(_ profile: ConnectionProfile) -> URL {
    let identity = SHA256.hash(data: Data(profile.credentialAccount.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent("\(profile.id)-\(identity).jpg")
  }
  func load(_ profile: ConnectionProfile) -> Data? { try? Data(contentsOf: url(profile)) }
  func remove(_ profile: ConnectionProfile) {
    try? FileManager.default.removeItem(at: url(profile))
  }
  func capture(_ frame: VideoFrame, profile: ConnectionProfile) -> Data? {
    var image = CIImage(cvPixelBuffer: frame.buffer)
      .transformed(by: CGAffineTransform(scaleX: frame.pixelAspect, y: 1))
    let rotation = ((frame.rotation + profile.rotation) % 360 + 360) % 360
    image = image.oriented(
      rotation == 90 ? .right : rotation == 180 ? .down : rotation == 270 ? .left : .up)
    let scale = min(1, 640 / max(image.extent.width, image.extent.height))
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard
      let data = context.jpegRepresentation(
        of: image,
        colorSpace: CGColorSpaceCreateDeviceRGB(),
        options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.78])
    else { return nil }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: url(profile), options: [.atomic, .completeFileProtection])
    return data
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
