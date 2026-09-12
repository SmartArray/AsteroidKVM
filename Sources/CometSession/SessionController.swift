import AVFoundation
// A session owns authentication, media, HID state, and reconnection independently of its window.
import AppKit
import Combine
import CometAgent
import CometCore
import CometMedia

@MainActor public final class SessionController: ObservableObject, Identifiable {
  public let id: UUID
  @Published public private(set) var profile: ConnectionProfile {
    didSet {
      // Invalidate context on every identity mutation; endpoint sanitization happens before publishing the value.
      if profile.agentIdentity != oldValue.agentIdentity {
        pendingCertificate = nil
        onAgentIdentityChanged?()
      }
    }
  }
  @Published public var phase = ConnectionPhase.disconnected
  @Published public var state = DeviceState()
  @Published public var message: String?
  @Published public var captured = false
  @Published public var pasting = false
  @Published public var microphone = false
  @Published public var mediaFeatures: JSONValue = .null
  @Published public var ocrSelecting = false
  @Published public var ocrBusy = false
  @Published public var ocrText: String?
  @Published public var ocrLanguages: [String] = []
  @Published public var metrics = VideoMetrics()
  @Published public private(set) var mediaConnectionsStarted = 0
  @Published public var pendingCertificate: String?
  public let mailbox = FrameMailbox()
  public var input = InputEngine()
  public var output: HIDOutput?
  public var onProfileChanged: ((ConnectionProfile) -> Void)?
  // Agent ownership is independent of window focus; manual capture explicitly interrupts it.
  @Published public var agentOwnsInput = false
  // Preview coordinates are local presentation state and never enter screenshots or the HID queue.
  @Published public var agentClickPreview: AgentClickPreview?
  public var onAgentInterruption: (() -> Void)?
  public var onAgentIdentityChanged: (() -> Void)?
  public var onCapture: ((UUID) -> Void)?
  public private(set) var api: CometAPI?
  private var media: (any MediaConnection)?
  private let mediaFactory: @MainActor (CometAPI, FrameMailbox) -> any MediaConnection
  private var lastStateMessage = Date()
  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var connectTask: Task<Void, Never>?
  private var ocrTask: Task<Void, Never>?
  private var settingsTasks: [String: Task<Void, Never>] = [:]
  private var generation = UUID()
  private var password: String?
  private var suppliedToken: String?
  private var reconnectAttempt = 0
  private var shouldReconnect = false
  public var active: Bool { [.connected, .noSignal].contains(phase) }

  // Credentials passed to a session remain memory-only unless the profile editor explicitly saves them.
  public init(
    profile: ConnectionProfile, password: String? = nil, token: String? = nil,
    mediaFactory: @escaping @MainActor (CometAPI, FrameMailbox) -> any MediaConnection = {
      JanusClient(api: $0, mailbox: $1)
    }
  ) {
    self.mediaFactory = mediaFactory
    id = profile.id
    self.profile = profile
    self.password = password
    suppliedToken = token
    configureInput()
  }

  // Clear pending key state before applying the current capability, keymap, and typing preferences.
  public func configureInput() {
    _ = input.releaseAll()
    input.nativeLayout = profile.nativeLayout
    input.mappedTextSupported = state.mappedText
    input.keymap = profile.keymap
    input.pasteEnabled = profile.pasteEnabled
  }

  // Release capture before a preference change can alter input interpretation.
  public func updateProfile(_ change: (inout ConnectionProfile) -> Void) {
    onAgentInterruption?()
    releaseCapture()
    var updated = profile
    change(&updated)
    profile = updated.securingReplacement(of: profile)
    configureInput()
    onProfileChanged?(profile)
    media?.setMuted(profile.muted)
  }
  // Editing endpoint identity ends the old session before adopting new credentials or certificate policy.
  public func replaceProfile(_ updated: ConnectionProfile, password: String?) async {
    await disconnect()
    self.profile = updated.securingReplacement(of: profile)
    self.password = password?.isEmpty == false ? password : nil
    suppliedToken = nil
    configureInput()
  }

  // Open or establish the selected session using its own profile and credentials.
  public func connect(password: String? = nil) {
    if let password { self.password = password }
    guard !active, connectTask == nil else { return }
    shouldReconnect = true
    let ticket = generation
    connectTask = Task { [weak self] in
      guard let self else { return }
      await establish()
      if ticket == generation { connectTask = nil }
    }
  }

  // Connect in stages, with capability discovery preceding any optional input or device controls.
  private func establish() async {
    let ticket = generation
    phase = reconnectAttempt == 0 ? .connecting : .reconnecting
    message = nil
    let api = CometAPI(profile: profile, token: suppliedToken)
    self.api = api
    do {
      if suppliedToken == nil {
        let secret =
          try password
          ?? (profile.rememberPassword ? try PasswordStore().password(for: profile) : nil)
        guard let secret else { throw CometError.authentication }
        try await api.login(
          password: secret,
          onApprovalRequired: { @MainActor [weak self] in
            self?.message = "Approve this sign-in on the Comet’s screen."
          })
      }
      let discovered = try await api.discover()
      guard ticket == generation, !Task.isCancelled else {
        await api.close()
        return
      }
      state = discovered
      if !state.availableKeymaps.contains(profile.keymap),
        let keymap = state.keymaps["keymaps"]["default"].string
      {
        profile.keymap = keymap
      }
      configureInput()
      let ws = try await api.socket("/api/ws", query: ["stream": "true"])
      socket = ws
      let output = HIDOutput(
        send: { event in
          try await ws.send(.string(String(decoding: event.json.data(), as: UTF8.self)))
        }, paste: { text, keymap in try await api.paste(text, keymap: keymap) })
      output.onPasteChanged = { [weak self] busy in self?.pasting = busy }
      output.onError = { [weak self] error in
        self?.message = error.localizedDescription
        self?.onAgentInterruption?()
        self?.releaseCapture()
      }
      self.output = output
      lastStateMessage = Date()
      startStateReceiver(ws, ticket: ticket)
      let media = mediaFactory(api, mailbox)
      self.media = media
      mediaConnectionsStarted += 1
      media.onFeatures = { [weak self] features in self?.mediaFeatures = features }
      media.onConnected = { [weak self] in self?.reconnectAttempt = 0 }
      media.onError = { [weak self] error in self?.connectionFailed(error) }
      try await media.start(microphone: microphone, muted: profile.muted)
      guard ticket == generation else { return }
      phase = state.online == false ? .noSignal : .connected
      heartbeatTask = Task { [weak self] in
        var tick = 0
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: .seconds(1))
            guard let self, ticket == generation else { return }
            guard Date().timeIntervalSince(lastStateMessage) < 20 else { throw URLError(.timedOut) }
            metrics = mailbox.statistics()
            tick += 1
            if tick % 5 == 0 {
              try await ws.send(.string("{\"event_type\":\"ping\",\"event\":{}}"))
            }
            // Poll optional device objects only when discovery confirmed their endpoints.
            if tick % 10 == 0 {
              if state.config != .null {
                state.config = try await api.call("/api/system/get_config")["config"]
              }
              if state.system != .null {
                state.system = try await api.call("/api/system/get_param")
              }
              if state.functions != .null {
                state.functions = try await api.call(
                  "/api/system/otg_functions", query: ["wait_ready": "false"])
              }
            }
          } catch {
            if !Task.isCancelled { self?.connectionFailed(error) }
            return
          }
        }
      }
    } catch {
      guard ticket == generation, !Task.isCancelled else { return }
      if case CometError.certificate(let fingerprint) = error {
        pendingCertificate = fingerprint
        phase = .disconnected
        shouldReconnect = false
      } else if case CometError.authentication = error {
        phase = .authenticating
        shouldReconnect = false
        suppliedToken = nil
      } else {
        phase = .disconnected
      }
      message = error.localizedDescription
      await cleanConnections()
    }
  }

  // State events update only their subsystem; mapped-text failures are visible and never retried.
  private func startStateReceiver(_ ws: URLSessionWebSocketTask, ticket: UUID) {
    receiveTask = Task { [weak self] in
      guard let self else { return }
      do {
        while !Task.isCancelled, ticket == generation {
          let message = try await ws.receive()
          let data: Data
          switch message {
          case .string(let text): data = Data(text.utf8)
          case .data(let bytes): data = bytes
          @unknown default: continue
          }
          guard let value = try? JSONValue.decode(data) else { continue }
          lastStateMessage = Date()
          let event = value["event"]
          switch value["event_type"].string {
          case "hid": state.hid = event
          case "hid_keymaps":
            if state.keymaps != event {
              releaseCapture()
              state.keymaps = event
              configureInput()
            }
          case "streamer":
            state.streamer = event
            if active { phase = state.online == false ? .noSignal : .connected }
          case "mapped_text_result":
            if event["mapped"].bool == false {
              self.message =
                "The target keymap could not type “\(event["text"].text)”. No retry was sent."
            }
          default: break
          }
        }
      } catch { if !Task.isCancelled && ticket == generation { connectionFailed(error) } }
    }
  }

  // Reconnection invalidates pending input and uses a cancellable bounded backoff, including wake recovery.
  private func connectionFailed(_ error: Error) {
    onAgentInterruption?()
    guard shouldReconnect, phase != .reconnecting else { return }
    releaseCapture()
    phase = .reconnecting
    message = error.localizedDescription
    generation = UUID()
    reconnectAttempt += 1
    let ticket = generation
    connectTask?.cancel()
    connectTask = Task { [weak self] in
      guard let self else { return }
      await cleanConnections()
      do { try await Task.sleep(for: .seconds(min(15, 1 << min(reconnectAttempt, 4)))) } catch {
        if ticket == generation { connectTask = nil }
        return
      }
      guard ticket == generation, shouldReconnect, !Task.isCancelled else {
        if ticket == generation { connectTask = nil }
        return
      }
      await establish()
      guard ticket == generation else { return }
      connectTask = nil
      if phase == .disconnected && shouldReconnect {
        connectionFailed(URLError(.cannotConnectToHost))
      }
    }
  }

  // Invalidate queued work and release input before the Mac sleeps.
  public func suspend() {
    onAgentInterruption?()
    guard shouldReconnect else { return }
    releaseCapture()
    generation = UUID()
    connectTask?.cancel()
    connectTask = nil
    Task {
      await cleanConnections()
      phase = .reconnecting
    }
  }

  // Resume eligible sessions through the normal bounded reconnection path.
  public func wake() {
    if shouldReconnect {
      phase = .disconnected
      connectionFailed(URLError(.networkConnectionLost))
    }
  }

  // Discard pending input and selection so a focus transition cannot leave remote keys held.
  public func releaseCapture() {
    captured = false
    _ = input.releaseAll()
    // Losing video-window focus must not discard agent typing while the chat owns input.
    if !agentOwnsInput { output?.releaseAll() }
    cancelOCR()
  }

  // Grant input only to an active session after the registry releases its other sessions.
  public func capture() {
    onAgentInterruption?()
    guard active, !pasting, !ocrSelecting, !ocrBusy else { return }
    onCapture?(id)
    captured = true
    configureInput()
  }

  // Flush key releases before closing a socket; server disconnect cleanup is the final backstop.
  public func disconnect(logout: Bool = false) async {
    onAgentInterruption?()
    shouldReconnect = false
    generation = UUID()
    connectTask?.cancel()
    connectTask = nil
    releaseCapture()
    if pasting {
      output?.stop()
    } else {
      // Give balanced releases a brief chance to drain; a stalled socket must not indefinitely block closure.
      let closingOutput = output
      let deadline = Task {
        do {
          try await Task.sleep(for: .seconds(2))
          closingOutput?.stop()
        } catch {}
      }
      await closingOutput?.flush()
      deadline.cancel()
    }
    if logout {
      do { try await api?.logout() } catch { message = error.localizedDescription }
      password = nil
      suppliedToken = nil
    }
    await cleanConnections()
    phase = .disconnected
  }

  // Cancel owned tasks, media, sockets, and API transport before another connection is established.
  private func cleanConnections() async {
    receiveTask?.cancel()
    heartbeatTask?.cancel()
    receiveTask = nil
    heartbeatTask = nil
    settingsTasks.values.forEach { $0.cancel() }
    settingsTasks.removeAll()
    output?.stop()
    output = nil
    microphone = false
    media?.stop()
    media = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    let closingAPI = api
    api = nil
    await closingAPI?.close()
  }

  // Store the specifically approved leaf fingerprint and retry this device’s connection.
  public func approveCertificate() {
    guard let pendingCertificate else { return }
    profile.certificateSHA256 = pendingCertificate
    self.pendingCertificate = nil
    onProfileChanged?(profile)
    connect()
  }

  // Native paste locks live input for the operation and never retains clipboard text after completion.
  public func paste() {
    onAgentInterruption?()
    guard active, !pasting, let text = NSPasteboard.general.string(forType: .string) else { return }
    _ = input.releaseAll()
    output?.paste(text, keymap: profile.keymap)
  }

  // Send balanced remote shortcut transitions through the session’s ordered input queue.
  public func shortcut(_ codes: [String]) {
    onAgentInterruption?()
    guard active, !pasting else { return }
    releaseCapture()
    output?.enqueue(codes.map { .key($0, true) } + codes.reversed().map { .key($0, false) })
  }

  // Mutate just the chosen encoder field and debounce controls that can generate repeated changes.
  public func setVideo(_ changes: [String: String], debounce: Bool = false) {
    onAgentInterruption?()
    guard let api else { return }
    let key = changes.keys.sorted().joined(separator: ",")
    settingsTasks[key]?.cancel()
    settingsTasks[key] = Task { [weak self] in
      do {
        if debounce { try await Task.sleep(for: .milliseconds(350)) }
        try await api.call("/api/streamer/set_params", method: "POST", query: changes)
        self?.state.streamer = try await api.call("/api/streamer")
      } catch { if !Task.isCancelled { self?.message = error.localizedDescription } }
    }
  }

  // Apply only the chosen USB function and refresh the device’s resulting state.
  public func setDevice(_ key: String, value: Bool) {
    onAgentInterruption?()
    performSetting(
      "device:" + key,
      operation: { api in
        try await api.call("/api/system/otg_functions", method: "POST", query: [key: String(value)])
        return try await api.call("/api/system/otg_functions", query: ["wait_ready": "false"])
      }, apply: { $0.functions = $1 })
  }

  // Write a confirmed device parameter through the session-owned settings lifecycle.
  public func setSystemParameter(_ key: String, value: String) {
    onAgentInterruption?()
    performSetting(
      "system:" + key,
      operation: { api in
        try await api.call("/api/system/set_param", method: "POST", query: [key: value])
      }, apply: { $0.system = $1 })
  }

  // Update a supported HID option and read its actual resulting state.
  public func setHID(_ key: String, value: String) {
    onAgentInterruption?()
    performSetting(
      "hid:" + key,
      operation: { api in
        try await api.call("/api/hid/set_params", method: "POST", query: [key: value])
        return try await api.call("/api/hid")
      }, apply: { $0.hid = $1 })
  }

  // Schedule periods use the daemon's daily HH:MM contract; an empty list disables scheduled activation.
  public func setJigglerSchedule(_ periods: [JSONValue]) {
    performSetting(
      "jiggler-schedule",
      operation: { api in
        try await api.call(
          "/api/hid/set_jiggler_schedule", method: "POST",
          body: JSONValue.object(["periods": .array(periods)]).data(),
          contentType: "application/json")
        return try await api.call("/api/hid")
      }, apply: { $0.hid = $1 })
  }

  // Own device mutations with the connection so delayed responses cannot update a replacement session.
  private func performSetting(
    _ key: String, operation: @escaping (CometAPI) async throws -> JSONValue,
    apply: @escaping (inout DeviceState, JSONValue) -> Void
  ) {
    guard active, let api else { return }
    releaseCapture()
    let ticket = generation
    settingsTasks[key]?.cancel()
    settingsTasks[key] = Task { [weak self] in
      do {
        let result = try await operation(api)
        guard let self, ticket == generation, !Task.isCancelled else { return }
        apply(&state, result)
      } catch { if !Task.isCancelled { self?.message = error.localizedDescription } }
    }
  }

  // Request access on demand and renegotiate the session only when forwarding changes.
  public func setMicrophone(_ enabled: Bool) {
    let ticket = generation
    settingsTasks["microphone"]?.cancel()
    settingsTasks["microphone"] = Task {
      if enabled {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
          message = "Microphone access was denied. Enable it in macOS Privacy & Security settings."
          return
        }
      }
      guard ticket == generation, !Task.isCancelled, let media else { return }
      releaseCapture()
      media.stop()
      microphone = enabled
      mediaConnectionsStarted += 1
      do { try await media.start(microphone: enabled, muted: profile.muted) } catch {
        message = error.localizedDescription
        microphone = false
      }
    }
  }

  // Release capture before restarting the selected appliance and entering reconnection.
  public func reboot() {
    onAgentInterruption?()
    guard active, let api else { return }
    let ticket = generation
    releaseCapture()
    settingsTasks["reboot"] = Task {
      do {
        try await api.call("/api/upgrade/reboot")
        guard ticket == generation, !Task.isCancelled else { return }
        connectionFailed(URLError(.networkConnectionLost))
      } catch { if !Task.isCancelled { message = error.localizedDescription } }
    }
  }

  // Selection freezes a retained renderer frame; recognition results and images are cleared on dismissal.
  public func startOCR() {
    onAgentInterruption?()
    releaseCapture()
    guard mailbox.snapshot() != nil else {
      message = "Text Recognition needs a received video frame."
      return
    }
    ocrSelecting = true
  }

  // Recognize only the selected snapshot and deliver its result without moving live video through UI state.
  public func recognize(frame: VideoFrame, crop: CGRect) {
    ocrSelecting = false
    ocrBusy = true
    ocrTask = Task { [weak self] in
      guard let self else { return }
      do {
        let text = try await TextRecognition.recognize(
          frame: frame, crop: crop, languages: ocrLanguages)
        if !Task.isCancelled { ocrText = text }
      } catch { if !Task.isCancelled { message = error.localizedDescription } }
      ocrBusy = false
    }
  }

  // Cancel pending recognition and clear selection flags without retaining a result.
  public func cancelOCR() {
    ocrSelecting = false
    ocrTask?.cancel()
    ocrTask = nil
    ocrBusy = false
  }
}
