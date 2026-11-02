import Combine
import CometCore
import CometMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@MainActor public final class AudioNotificationController: ObservableObject {
  @Published public private(set) var status = "Disabled"
  @Published public private(set) var lastDelivery: Date?
  @Published public private(set) var lastError: String?
  @Published public private(set) var sending = false
  // A session can pause delivery without changing its saved webhook configuration.
  @Published public private(set) var isPaused = false
  private var profile: ConnectionProfile?
  private var connected = false
  private var gate = AudioNotificationGate()
  private var generation = UUID()
  private var delivery: Task<Void, Never>?
  private let send: (URL, AudioWebhookPayload) async throws -> Void
  private let clock: () -> TimeInterval
  private let capture: (VideoFrame) async throws -> AudioWebhookPayload.Screenshot

  public var isArmed: Bool {
    !isPaused && profile?.audioNotifications?.enabled == true
      && profile?.audioNotifications?.endpointURL != nil
  }

  public init(
    send: @escaping (URL, AudioWebhookPayload) async throws -> Void = {
      try await AudioWebhookClient().send(to: $0, payload: $1)
    },
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    capture: @escaping (VideoFrame) async throws -> AudioWebhookPayload.Screenshot = {
      try await AudioNotificationController.screenshot($0)
    }
  ) {
    self.send = send
    self.clock = clock
    self.capture = capture
  }

  public func configure(profile: ConnectionProfile, connected: Bool) {
    let identityChanged = self.profile?.agentIdentity != profile.agentIdentity || self.profile?.id != profile.id
    let justEnabled = self.profile?.audioNotifications?.enabled != true && profile.audioNotifications?.enabled == true
    let changed = self.profile?.audioNotifications != profile.audioNotifications
      || identityChanged || self.profile?.name != profile.name
    if changed || !connected {
      cancelDelivery()
      lastError = nil
    }
    if identityChanged {
      gate = AudioNotificationGate()
      lastDelivery = nil
    }
    if identityChanged || justEnabled { isPaused = false }
    self.profile = profile
    self.connected = connected
    updateStatus()
  }

  public func setPaused(_ paused: Bool) {
    guard paused != isPaused else { return }
    isPaused = paused
    if paused { cancelDelivery() }
    lastError = nil
    updateStatus()
  }

  // Disconnect, sleep, and profile replacement invalidate work before its next asynchronous boundary.
  public func stop() {
    connected = false
    cancelDelivery()
    updateStatus()
  }

  public func receive(level: Double, mailbox: FrameMailbox) {
    guard connected, isArmed, !sending, let profile,
      let preferences = profile.audioNotifications, preferences.enabled,
      let url = preferences.endpointURL else { return }
    guard mailbox.frameAge < 3, let frame = mailbox.snapshot() else {
      status = "Waiting for a live screenshot"
      return
    }
    guard gate.admit(level: level, preferences: preferences, now: clock()) else { return }
    let timestamp = Date()
    let ticket = generation
    sending = true
    lastError = nil
    status = "Sending…"
    delivery = Task { [weak self, capture, send] in
      do {
        let screenshot = try await capture(frame)
        guard let self, ticket == generation, !Task.isCancelled, connected else { return }
        let payload = AudioWebhookPayload(profile: profile, level: level,
          screenshot: screenshot, timestamp: timestamp)
        try await send(url, payload)
        guard ticket == generation, !Task.isCancelled else { return }
        lastDelivery = Date()
        status = "Delivered"
      } catch {
        guard let self, ticket == generation, !Task.isCancelled else { return }
        lastError = (error as? AudioNotificationError)?.description ?? "Could not prepare or send the notification."
        status = "Delivery failed"
      }
      guard let self, ticket == generation else { return }
      sending = false
      delivery = nil
    }
  }

  private func cancelDelivery() {
    generation = UUID()
    delivery?.cancel()
    delivery = nil
    sending = false
  }

  private func updateStatus() {
    guard let preferences = profile?.audioNotifications, preferences.enabled else {
      status = "Disabled"
      return
    }
    if preferences.endpointURL == nil { status = "Enter a valid webhook URL" }
    else if isPaused { status = "Paused from status bar" }
    else if !connected { status = "Waiting for connection" }
    else if !sending { status = "Listening for audio" }
  }

  // Only the selected KVM's decoded frame is encoded. No Mac desktop capture or recording permission is needed.
  public nonisolated static func screenshot(_ frame: VideoFrame) async throws -> AudioWebhookPayload.Screenshot {
    try await Task.detached(priority: .utility) {
      let context = CIContext(options: [.cacheIntermediates: false])
      let source = CIImage(cvPixelBuffer: frame.buffer)
      let width = source.extent.width, height = source.extent.height
      guard width > 0, height > 0, width <= 8192, height <= 8192 else {
        throw AudioNotificationError("Could not capture the KVM screenshot.")
      }
      let scale = min(1, 1600 / max(width, height))
      let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      guard let cg = context.createCGImage(image, from: image.extent.integral) else {
        throw AudioNotificationError("Could not capture the KVM screenshot.")
      }
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
      else { throw AudioNotificationError("Could not encode the KVM screenshot.") }
      CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw AudioNotificationError("Could not encode the KVM screenshot.")
      }
      return AudioWebhookPayload.Screenshot(jpeg: data as Data, width: cg.width, height: cg.height)
    }.value
  }
}
