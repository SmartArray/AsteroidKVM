// Coordinate conversation, observation, and input using a local gate that the model cannot override.
import Combine
import CometCore
import Foundation

@MainActor public final class AgentController: ObservableObject {
  @Published public private(set) var status: AgentStatus = .idle
  @Published public private(set) var messages: [AgentMessage] = []
  @Published public private(set) var detail =
    "Use your installed, signed-in Codex to control this remote computer."
  @Published public private(set) var actionCount = 0
  @Published public private(set) var controlMode: AgentControlMode = .review
  @Published public private(set) var pendingApproval: AgentApproval?
  @Published public private(set) var clickPreviewsEnabled = true
  @Published public private(set) var models: [AgentModel] = []
  @Published public private(set) var selectedModel = ""
  @Published public private(set) var selectedThinkingLevel = ""
  @Published public private(set) var configuredModel = ""
  @Published public private(set) var loadingModels = false
  @Published public private(set) var modelListError: String?
  private var proposedClick: AgentClickPreview?
  private var previewStarted: ContinuousClock.Instant?
  private var approvalContinuation: CheckedContinuation<Void, Error>?
  private var approvalDeadline: Task<Void, Never>?
  private var contextIdentity: String?
  private var connectionID = UUID()
  private var transcript = AgentTranscript()
  private let computer: any AgentComputer
  private let factory: @MainActor () throws -> any AgentTransport
  private var transport: (any AgentTransport)?
  private var threadID: String?
  private var turnID: String?
  private var generation = UUID()
  private var toolTask: Task<Void, Never>?
  private var startupTask: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?
  private var latestScreen: AgentScreen?
  private var pendingPrompt: String?
  private var turnStarting = false
  private var startupID = UUID()
  private var toolID = UUID()
  public var canResume: Bool {
    status == .paused && turnID == nil && !turnStarting && startupTask == nil && toolTask == nil
  }

  // Inject the remote computer and transport so the same state machine runs in app and E2E tests.
  public init(
    computer: any AgentComputer,
    transportFactory: @escaping @MainActor () throws -> any AgentTransport = {
      guard let executable = CodexTransport.installedExecutable() else {
        throw AgentError(
          "Install Codex CLI and run ‘codex login’, or choose its executable in Agent settings.")
      }
      return CodexTransport(executable: executable)
    }
  ) {
    self.computer = computer
    factory = transportFactory
  }

  // A model change closes the old thread and input lease while preserving the visible transcript for review.
  public func selectModel(_ id: String) {
    guard id != selectedModel, id.utf8.count <= 200 else { return }
    stop()
    selectedModel = id
    resetUnsupportedThinkingLevel()
    detail = "Model changed. Your next prompt starts a new Codex conversation."
  }

  // Resolve Codex default through its configuration so effort choices match the model that actually runs.
  public var currentModel: AgentModel? {
    models.first { $0.id == (selectedModel.isEmpty ? configuredModel : selectedModel) }
  }
  public var thinkingLevels: [String] { currentModel?.supportedReasoningEfforts ?? [] }
  public var automaticThinkingLevel: String { currentModel?.reasoningEffort ?? "medium" }

  // Start a fresh thread when effort changes, releasing input and keeping the visible transcript intact.
  public func selectThinkingLevel(_ level: String) {
    guard level != selectedThinkingLevel, level.utf8.count <= 32,
      level.isEmpty || models.isEmpty || thinkingLevels.contains(level)
    else { return }
    stop()
    selectedThinkingLevel = level
    detail = "Thinking level changed. Your next prompt starts a new Codex conversation."
  }

  // A choice that belongs to another model must never reach the new model's protocol request.
  private func resetUnsupportedThinkingLevel() {
    if !models.isEmpty && !selectedThinkingLevel.isEmpty
      && !thinkingLevels.contains(selectedThinkingLevel)
    {
      selectThinkingLevel("")
    }
  }

  // Discover models in a separate short-lived process without acquiring input, reading screens, or starting inference.
  public func refreshModels() async {
    guard !loadingModels else { return }
    loadingModels = true
    modelListError = nil
    defer { loadingModels = false }
    do {
      let connection = try factory()
      defer { connection.close() }
      try await withTaskCancellationHandler {
        try connection.start()
        _ = try await connection.request(
          "initialize",
          .object([
            "clientInfo": .object([
              "name": .string("comet_kvm_models"), "version": .string("1.0.0"),
            ])
          ]))
        try connection.notify("initialized", .object([:]))
        let configuration = try await connection.request(
          "config/read", .object(["includeLayers": .bool(false)]))
        let defaultModel = configuration["config"]["model"].string ?? ""
        var result: [AgentModel] = []
        var cursor: String?
        var cursors = Set<String>()
        for _ in 0..<10 {
          try Task.checkCancellation()
          var params: [String: JSONValue] = ["limit": .number(100), "includeHidden": .bool(false)]
          if let cursor { params["cursor"] = .string(cursor) }
          let page = try await connection.request("model/list", .object(params))
          guard case .array(let entries) = page["data"], entries.count <= 100 else {
            throw AgentError("Codex returned an invalid model catalog.")
          }
          for model in entries.compactMap(AgentModel.init)
          where !result.contains(where: { $0.id == model.id }) {
            result.append(model)
          }
          cursor = page["nextCursor"].string
          guard let cursor else {
            try Task.checkCancellation()
            configuredModel = defaultModel
            models = result
            resetUnsupportedThinkingLevel()
            return
          }
          guard cursors.insert(cursor).inserted else { break }
        }
        throw AgentError("Codex returned too many model catalog pages.")
      } onCancel: {
        Task { @MainActor in connection.close() }
      }
    } catch {
      if !Task.isCancelled { modelListError = String(error.localizedDescription.prefix(500)) }
    }
  }

  // Start only on explicit user submission; opening the chat never transmits pixels or controls the device.
  public func send(_ text: String) {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, prompt.count <= 16000, !status.busy, status != .paused else { return }
    guard append(.user, prompt) else { return }
    begin(prompt)
  }

  // Initialize one ephemeral thread, disable inherited MCP servers, and reuse context for follow-up turns.
  private func begin(_ prompt: String) {
    // A second identity check protects adapters even when a lifecycle callback was missed.
    if let contextIdentity, contextIdentity != computer.identity {
      resetTarget()
      return
    }
    contextIdentity = computer.identity
    do { try computer.acquire() } catch {
      fail(error.localizedDescription)
      return
    }
    pendingPrompt = prompt
    generation = UUID()
    let ticket = generation
    status = transport == nil ? .starting : .running
    detail = "Codex is working on this remote computer."
    actionCount = 0
    latestScreen = nil
    let startID = UUID()
    startupID = startID
    startupTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if startupID == startID {
          startupTask = nil
          objectWillChange.send()
        }
      }
      guard generation == ticket, startupID == startID else { return }
      do {
        if transport == nil || threadID == nil {
          transport?.onClose = nil
          transport?.close()
          let connection = try factory()
          transport = connection
          // A replaced transport must never deliver queued events into its successor's conversation.
          let sourceID = UUID()
          connectionID = sourceID
          connection.onEvent = { [weak self] value in
            guard let self, connectionID == sourceID else { return }
            event(value)
          }
          connection.onClose = { [weak self] message in
            guard let self, connectionID == sourceID else { return }
            fail(message)
          }
          try connection.start()
          _ = try await connection.request(
            "initialize",
            .object([
              "clientInfo": .object([
                "name": .string("comet_kvm"), "title": .string("Comet KVM"),
                "version": .string("1.0.0"),
              ]),
              "capabilities": .object(["experimentalApi": .bool(true)]),
            ]))
          try connection.notify("initialized", .object([:]))
          let account = try await connection.request(
            "account/read", .object(["refreshToken": .bool(false)]))
          guard account["account"] != .null || account["requiresOpenaiAuth"].bool == false else {
            throw AgentError("Sign in with ‘codex login’ in Terminal, then try again.")
          }
          let config = try await connection.request(
            "config/read", .object(["includeLayers": .bool(false)]))
          var overrides = CodexTransport.configuration
          // Respect each model's supported effort levels while retaining medium where it is available.
          // Validate against the selected model's catalog again before sending a saved preference.
          let effort =
            thinkingLevels.contains(selectedThinkingLevel)
            ? selectedThinkingLevel : automaticThinkingLevel
          overrides["model_reasoning_effort"] = .string(effort)
          for name in config["config"]["mcp_servers"].object.keys {
            overrides["mcp_servers.\(name).enabled"] = .bool(false)
          }
          var threadParameters: [String: JSONValue] = [
            "ephemeral": .bool(true), "approvalPolicy": .string("untrusted"),
            "sandbox": .string("read-only"),
            "baseInstructions": .string(
              AgentTool.instructions + "\nLocal control mode: " + controlMode.rawValue),
            "developerInstructions": .string(AgentTool.instructions),
            "config": .object(overrides), "dynamicTools": AgentTool.definitions,
            "environments": .array([]),
          ]
          if !selectedModel.isEmpty { threadParameters["model"] = .string(selectedModel) }
          let thread = try await connection.request("thread/start", .object(threadParameters))
          guard let id = thread["thread"]["id"].string else {
            throw AgentError("Codex did not return a thread ID.")
          }
          guard startupID == startID else { return }
          threadID = id
        }
        guard generation == ticket, [.starting, .running].contains(status), let transport,
          let threadID
        else { return }
        status = .running
        turnStarting = true
        defer {
          if startupID == startID {
            turnStarting = false
            objectWillChange.send()
          }
        }
        let result = try await transport.request(
          "turn/start",
          .object([
            "threadId": .string(threadID),
            "input": .array([.object(["type": .string("text"), "text": .string(prompt)])]),
          ]))
        guard let id = result["turn"]["id"].string else {
          throw AgentError("Codex did not return a turn ID.")
        }
        guard startupID == startID else { return }
        turnID = id
        pendingPrompt = nil
        if generation != ticket || status != .running {
          await interrupt()
          return
        }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(900)) } catch { return }
          self?.pause(reason: "Paused after 15 minutes. Review progress before resuming.")
        }
      } catch {
        if status != .paused && status != .pausing && generation == ticket {
          fail(error.localizedDescription)
        }
      }
    }
  }

  // Close the input gate synchronously; interruption of remote model work happens afterward.
  public func pause(reason: String = "Paused. Review the remote screen before resuming.") {
    guard status == .running || status == .starting else { return }
    generation = UUID()
    status = .pausing
    detail = reason
    latestScreen = nil
    clearClickPreview()
    cancelApproval()
    toolTask?.cancel()
    computer.release()
    watchdog?.cancel()
    Task { [weak self] in
      guard let self else { return }
      await interrupt()
      if status == .pausing { status = .paused }
    }
  }

  // Wait for turn completion before resuming; Codex preserves completed context, while a new screenshot is required.
  private func interrupt() async {
    guard let transport, let threadID, let turnID else { return }
    let ticket = generation
    do {
      _ = try await transport.request(
        "turn/interrupt", .object(["threadId": .string(threadID), "turnId": .string(turnID)]))
    } catch {
      if generation == ticket && (status == .paused || status == .pausing) {
        fail("Could not interrupt Codex. Remote input is stopped; start a new request.")
      }
    }
  }

  // Reuse any prompt paused before submission; otherwise continue the existing interrupted conversation.
  public func resume() {
    guard canResume else { return }
    guard append(.notice, "Resumed. Codex will read the current screen before continuing.") else {
      return
    }
    begin(
      pendingPrompt
        ?? "Continue the previous user task from the current screen. An interrupted action may be only partially complete. Read comet_screen first and inspect the result before deciding what remains."
    )
  }

  // Stop is immediate and final for the subprocess; chat remains visible until explicitly cleared.
  public func stop() {
    clearClickPreview()
    generation = UUID()
    connectionID = UUID()
    cancelApproval()
    status = .idle
    detail = "Stopped. Send a new request to start a new Codex conversation."
    toolTask?.cancel()
    startupTask?.cancel()
    startupID = UUID()
    startupTask = nil
    toolID = UUID()
    toolTask = nil
    watchdog?.cancel()
    computer.release()
    transport?.onClose = nil
    transport?.close()
    transport = nil
    threadID = nil
    pendingPrompt = nil
    turnID = nil
    latestScreen = nil
    turnStarting = false
  }

  // Clearing is explicit because stopping control should leave the conversation available for review.
  public func clear() {
    stop()
    transcript.clear()
    messages = []
    actionCount = 0
  }

  // Route only this thread's visible prose and the two registered remote tools; reject every other server request.
  private func event(_ event: JSONValue) {
    guard contextIdentity == computer.identity else {
      resetTarget()
      return
    }
    let method = event["method"].text
    let params = event["params"]
    if event["id"] != .null {
      guard method == "item/tool/call", params["threadId"].string == threadID else {
        try? transport?.reject(
          id: event["id"],
          message:
            "Only Comet remote-screen tools are available. Ask the user in chat if you need clarification."
        )
        return
      }
      runTool(id: event["id"], params: params)
      return
    }
    guard params["threadId"].string == threadID else { return }
    switch method {
    case "turn/started": turnID = params["turn"]["id"].string
    case "item/agentMessage/delta":
      let id = params["itemId"].text
      let delta = params["delta"].text
      storeMessage(AgentMessage(id: id, kind: .assistant, text: delta), delta: true)
    case "item/completed":
      let item = params["item"]
      if item["type"].string == "agentMessage", let text = item["text"].string {
        storeMessage(AgentMessage(id: item["id"].text, kind: .assistant, text: text))
      }
    case "turn/completed":
      guard turnID == nil || turnID == params["turn"]["id"].string else { return }
      turnID = nil
      cancelApproval()
      watchdog?.cancel()
      computer.release()
      if params["turn"]["status"].string == "failed" {
        fail(params["turn"]["error"]["message"].string ?? "Codex could not complete this request.")
      } else if status == .running {
        status = .idle
        detail = "Turn finished. Review the remote screen or send a follow-up."
      } else if status == .pausing {
        status = .paused
      }
    case "error":
      if params["willRetry"].bool != true {
        fail(params["error"]["message"].string ?? "Codex reported an error.")
      }
    default: break
    }
  }

  // Reject parallel or stale tool requests so one observation can authorize at most one action.
  private func runTool(id: JSONValue, params: JSONValue) {
    guard status == .running, toolTask == nil,
      turnID == nil || turnID == params["turnId"].string
    else {
      reply(
        id,
        error:
          "Remote input is paused or another action is in progress. Do not retry until resumed.")
      return
    }
    let ticket = generation
    let callID = UUID()
    toolID = callID
    let connection = transport
    toolTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if toolID == callID {
          clearClickPreview()
          toolTask = nil
          objectWillChange.send()
        }
      }
      do {
        guard computer.available else {
          throw AgentError("Remote screen is disconnected or unavailable.")
        }
        if params["tool"].string == "comet_action" {
          guard let screen = latestScreen else {
            throw AgentError("Read comet_screen before acting.")
          }
          let action = try AgentTool.parse(params["arguments"], screen: screen)
          guard actionCount < 150 else {
            pause(reason: "Paused after 150 actions. Review progress before resuming.")
            throw CancellationError()
          }
          // Consume the observation before waiting so a parallel call cannot reuse pending approval.
          latestScreen = nil
          // Show a valid proposed click throughout review, including when the user enables previews mid-review.
          if controlMode != .observe, Date().timeIntervalSince(screen.capturedAt) <= 60,
            case .click(let x, let y, _, _) = action
          {
            proposedClick = AgentClickPreview(x: x, y: y, screen: screen)
            refreshClickPreview()
          }
          try await authorize(action, screen: screen)
          try await waitForClickPreview()
          try Task.checkCancellation()
          guard generation == ticket, status == .running, contextIdentity == computer.identity,
            Date().timeIntervalSince(screen.capturedAt) <= 60
          else { throw CancellationError() }
          guard append(.action, describe(action)) else { throw CancellationError() }
          actionCount += 1
          try await computer.perform(action)
        } else if params["tool"].string == "comet_screen" {
          guard append(.action, "Read remote screen") else { throw CancellationError() }
        } else {
          throw AgentError("Unknown remote tool.")
        }
        try Task.checkCancellation()
        guard generation == ticket, status == .running else { throw CancellationError() }
        let screen = try await computer.screen()
        try Task.checkCancellation()
        guard generation == ticket, status == .running else { throw CancellationError() }
        latestScreen = screen
        try connection?.respond(
          id: id,
          result: .object([
            "success": .bool(true),
            "contentItems": .array([
              .object([
                "type": .string("inputText"),
                "text": .string(
                  "Remote screen \(screen.width)×\(screen.height). Origin top left. screenId: \(screen.id)"
                ),
              ]),
              .object(["type": .string("inputImage"), "imageUrl": .string(screen.imageURL)]),
            ]),
          ]))
      } catch {
        guard toolID == callID else { return }
        reply(
          id,
          error: error is CancellationError
            ? "Paused or stopped. The last action may be partially complete; re-read the screen before continuing."
            : error.localizedDescription)
      }
    }
  }

  // Keep tool failures in the visible timeline while never rendering binary image data or raw protocol envelopes.
  private func reply(_ id: JSONValue, error: String) {
    append(.notice, error)
    try? transport?.respond(
      id: id,
      result: .object([
        "success": .bool(false),
        "contentItems": .array([
          .object(["type": .string("inputText"), "text": .string(error)])
        ]),
      ]))
  }

  // Fail closed so transport errors cannot leave the agent holding remote input.
  private func fail(_ message: String) {
    stop()
    status = .failed
    detail = String(message.prefix(4096))
    append(.notice, detail)
  }

  // All message paths share count and byte budgets; violations release input without recursive error logging.
  @discardableResult private func storeMessage(_ message: AgentMessage, delta: Bool = false) -> Bool
  {
    do {
      try transcript.put(message, delta: delta)
      messages = transcript.messages
      return true
    } catch {
      stop()
      status = .failed
      detail = "Chat output exceeded its safety limit. Start a new conversation."
      return false
    }
  }

  // Ordinary timeline entries use the same budget as streamed assistant deltas and completions.
  @discardableResult private func append(_ kind: AgentMessage.Kind, _ text: String) -> Bool {
    storeMessage(.init(kind: kind, text: text))
  }

  // Preview visibility is independent of permission and can change while the current proposal is awaiting review.
  public func setClickPreviewsEnabled(_ enabled: Bool) {
    guard enabled != clickPreviewsEnabled else { return }
    clickPreviewsEnabled = enabled
    refreshClickPreview()
  }

  // Changing visibility never approves or rejects an action; reenabling starts a fresh preview interval.
  private func refreshClickPreview() {
    let preview = clickPreviewsEnabled ? proposedClick : nil
    computer.showClickPreview(preview)
    previewStarted = preview == nil ? nil : ContinuousClock.now
  }

  // Full control and rapid manual approval both leave at least one second to inspect the click target.
  private func waitForClickPreview() async throws {
    while let started = previewStarted, clickPreviewsEnabled,
      started.duration(to: .now) < .milliseconds(1100)
    {
      try await Task.sleep(for: .milliseconds(25))
    }
    try Task.checkCancellation()
  }

  // Every completion and cancellation removes the local marker before another action can reuse the surface.
  private func clearClickPreview() {
    proposedClick = nil
    previewStarted = nil
    computer.showClickPreview(nil)
  }

  // Changing permission is an explicit local action and invalidates any in-flight action or conversation turn.
  public func setControlMode(_ mode: AgentControlMode) {
    guard mode != controlMode else { return }
    stop()
    controlMode = mode
  }

  // Identity changes discard provider context and restore the safe default before the target can be reused.
  public func resetTarget() {
    clear()
    contextIdentity = nil
    controlMode = .review
    detail = "Remote identity changed. Start a new conversation for this target."
  }

  // Only this exact pending action can be approved; identity, freshness, and ownership are rechecked after await.
  public func approveAction(id: UUID) {
    guard let approval = pendingApproval, approval.id == id else { return }
    guard approval.targetIdentity == computer.identity else {
      resetTarget()
      return
    }
    guard status == .running, Date() <= approval.expiresAt else {
      cancelApproval()
      return
    }
    let continuation = approvalContinuation
    approvalContinuation = nil
    pendingApproval = nil
    approvalDeadline?.cancel()
    approvalDeadline = nil
    continuation?.resume()
  }

  // Rejecting an action pauses the whole turn, preventing immediate re-proposals from bypassing the decision.
  public func rejectAction(id: UUID) {
    guard pendingApproval?.id == id else { return }
    pause(reason: "Action rejected. Review the task before resuming.")
  }

  // The controller—not the model—enforces observation mode and holds exact actions for native approval.
  private func authorize(_ action: AgentAction, screen: AgentScreen) async throws {
    guard Date().timeIntervalSince(screen.capturedAt) <= 60 else {
      throw AgentError("Observation expired. Read comet_screen again before acting.")
    }
    switch controlMode {
    case .observe: throw AgentError("Observation-only mode blocks every action. Use comet_screen.")
    case .fullControl: return
    case .review:
      let approval = AgentApproval(
        id: UUID(), action: action, screen: screen, targetIdentity: computer.identity)
      try await withCheckedThrowingContinuation { continuation in
        approvalContinuation = continuation
        pendingApproval = approval
        detail = "Review the proposed action before allowing input."
        approvalDeadline = Task { [weak self] in
          do {
            try await Task.sleep(for: .seconds(max(0, approval.expiresAt.timeIntervalSinceNow)))
          } catch { return }
          self?.pause(reason: "Action approval expired. Resume to read the current screen.")
        }
      }
    }
  }

  // Cancellation always resolves the waiter once; no old approval can revive a stopped or replaced task.
  private func cancelApproval() {
    let continuation = approvalContinuation
    approvalContinuation = nil
    pendingApproval = nil
    approvalDeadline?.cancel()
    approvalDeadline = nil
    continuation?.resume(throwing: CancellationError())
  }

  // Describe visible effects with a short text preview instead of exposing raw tool arguments.
  private func describe(_ action: AgentAction) -> String {
    switch action {
    case .click(let x, let y, let button, let count):
      return "\(count == 2 ? "Double-click" : "Click") \(button) at (\(x), \(y))"
    case .key(let keys): return "Press " + keys.joined(separator: " + ")
    case .type(let text):
      return "Type \(text.count) characters: “\(text.prefix(100))\(text.count > 100 ? "…" : "")”"
    case .scroll(let delta): return "Scroll \(delta > 0 ? "down" : "up") \(abs(delta)) steps"
    case .wait(let ms): return "Wait \(ms) ms"
    }
  }
}
