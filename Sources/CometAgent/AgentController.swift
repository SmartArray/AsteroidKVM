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

  // Start only on explicit user submission; opening the chat never transmits pixels or controls the device.
  public func send(_ text: String) {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, prompt.count <= 16000, !status.busy, status != .paused else { return }
    append(.user, prompt)
    begin(prompt)
  }

  // Initialize one ephemeral thread, disable inherited MCP servers, and reuse context for follow-up turns.
  private func begin(_ prompt: String) {
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
          connection.onEvent = { [weak self] value in self?.event(value) }
          connection.onClose = { [weak self] message in self?.fail(message) }
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
          for name in config["config"]["mcp_servers"].object.keys {
            overrides["mcp_servers.\(name).enabled"] = .bool(false)
          }
          let thread = try await connection.request(
            "thread/start",
            .object([
              "ephemeral": .bool(true), "approvalPolicy": .string("untrusted"),
              "sandbox": .string("read-only"),
              "baseInstructions": .string(AgentTool.instructions),
              "developerInstructions": .string(AgentTool.instructions),
              "config": .object(overrides), "dynamicTools": AgentTool.definitions,
              "environments": .array([]),
            ]))
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
    append(.notice, "Resumed. Codex will read the current screen before continuing.")
    begin(
      pendingPrompt
        ?? "Continue the previous user task from the current screen. An interrupted action may be only partially complete. Read comet_screen first and inspect the result before deciding what remains."
    )
  }

  // Stop is immediate and final for the subprocess; chat remains visible until explicitly cleared.
  public func stop() {
    generation = UUID()
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
    messages.removeAll()
    actionCount = 0
  }

  // Route only this thread's visible prose and the two registered remote tools; reject every other server request.
  private func event(_ event: JSONValue) {
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
      if let index = messages.firstIndex(where: { $0.id == id }) {
        messages[index].text += delta
      } else {
        messages.append(AgentMessage(id: id, kind: .assistant, text: delta))
      }
    case "item/completed":
      let item = params["item"]
      if item["type"].string == "agentMessage", let text = item["text"].string {
        if let index = messages.firstIndex(where: { $0.id == item["id"].text }) {
          messages[index].text = text
        } else {
          messages.append(AgentMessage(id: item["id"].text, kind: .assistant, text: text))
        }
      }
    case "turn/completed":
      guard turnID == nil || turnID == params["turn"]["id"].string else { return }
      turnID = nil
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
          latestScreen = nil
          actionCount += 1
          append(.action, describe(action))
          try await computer.perform(action)
        } else if params["tool"].string == "comet_screen" {
          append(.action, "Read remote screen")
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
    detail = message
    append(.notice, message)
  }

  // Bound the local transcript independently of the provider context window.
  private func append(_ kind: AgentMessage.Kind, _ text: String) {
    messages.append(.init(kind: kind, text: text))
    if messages.count > 1000 { messages.removeFirst(messages.count - 1000) }
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
