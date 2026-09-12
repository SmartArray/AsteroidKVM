// Drive the real controller with adversarial protocol events while keeping all input inside an in-memory computer.
import CometAgent
import CometCore
import XCTest

@MainActor final class AgentSecurityTests: XCTestCase {
  // Observation mode rejects every action type, even when the model has a fresh valid screen identifier.
  func testObservationOnlyRejectsEveryAction() async throws {
    let computer = SecurityComputer()
    let transport = SecurityTransport()
    let agent = AgentController(computer: computer, transportFactory: { transport })
    defer { agent.stop() }
    agent.setControlMode(.observe)
    agent.send("Inspect only")
    try await wait { transport.started }
    for argument: JSONValue in [
      .object(["action": .string("click"), "x": .number(1), "y": .number(1)]),
      .object(["action": .string("key"), "keys": .array([.string("Enter")])]),
      .object(["action": .string("type"), "text": .string("marker\n")]),
      .object(["action": .string("scroll"), "delta": .number(1)]),
      .object(["action": .string("wait"), "milliseconds": .number(0)]),
    ] {
      try await observe(transport)
      let before = transport.responses.count
      transport.action(argument)
      try await wait { transport.responses.count > before }
      XCTAssertEqual(transport.responses.last?["success"].bool, false)
      XCTAssertNil(agent.pendingApproval)
    }
    XCTAssertTrue(computer.actions.isEmpty)
  }

  // Approval is exact, single-use, and cannot be replaced by a parallel model proposal.
  func testApprovalCannotBeReplayedOrSubstituted() async throws {
    let computer = SecurityComputer()
    let transport = SecurityTransport()
    let agent = AgentController(computer: computer, transportFactory: { transport })
    defer { agent.stop() }
    agent.send("Type one marker")
    try await wait { transport.started }
    try await observe(transport)
    transport.action(.object(["action": .string("type"), "text": .string("approved")]))
    try await wait { agent.pendingApproval != nil }
    let approval = try XCTUnwrap(agent.pendingApproval)
    transport.action(.object(["action": .string("type"), "text": .string("substituted")]))
    agent.approveAction(id: UUID())
    XCTAssertTrue(computer.actions.isEmpty)
    XCTAssertEqual(agent.pendingApproval?.id, approval.id)
    agent.approveAction(id: approval.id)
    try await wait { computer.actions.count == 1 && transport.responses.count == 3 }
    XCTAssertEqual(computer.actions, [.type("approved")])
    agent.approveAction(id: approval.id)
    XCTAssertEqual(computer.actions.count, 1)
  }

  // Pause and Stop invalidate a waiting approval before any asynchronous interruption response arrives.
  func testPauseAndStopCancelPendingApproval() async throws {
    for stop in [false, true] {
      let computer = SecurityComputer()
      let transport = SecurityTransport()
      let agent = AgentController(computer: computer, transportFactory: { transport })
      defer { agent.stop() }
      agent.send("Type")
      try await wait { transport.started }
      try await observe(transport)
      transport.action(.object(["action": .string("type"), "text": .string("marker")]))
      try await wait { agent.pendingApproval != nil }
      let approval = try XCTUnwrap(agent.pendingApproval)
      if stop { agent.stop() } else { agent.pause() }
      agent.approveAction(id: approval.id)
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertTrue(computer.actions.isEmpty)
      XCTAssertNil(agent.pendingApproval)
      XCTAssertFalse(computer.owned)
    }
  }

  // Even an adapter without lifecycle callbacks cannot reuse approval or provider context after changing identity.
  func testChangedTargetCannotReceiveOldApprovalOrThread() async throws {
    let computer = SecurityComputer()
    let transport = SecurityTransport()
    let agent = AgentController(computer: computer, transportFactory: { transport })
    defer { agent.stop() }
    agent.send("Type on A")
    try await wait { transport.started }
    try await observe(transport)
    transport.action(.object(["action": .string("type"), "text": .string("A-only")]))
    try await wait { agent.pendingApproval != nil }
    let approval = try XCTUnwrap(agent.pendingApproval)
    computer.identity = "B"
    agent.approveAction(id: approval.id)
    try await wait { agent.status == .idle }
    XCTAssertTrue(computer.actions.isEmpty)
    XCTAssertFalse(agent.canResume)
    agent.send("Inspect B")
    try await wait { transport.threadStarts == 2 }
    XCTAssertEqual(agent.controlMode, .review)
  }

  // A live stream does not make an old observation safe for delayed input, including full-control mode.
  func testApprovalExpiryPausesWithoutInput() async throws {
    let computer = SecurityComputer()
    computer.capturedAt = Date().addingTimeInterval(-59)
    let transport = SecurityTransport()
    let agent = AgentController(computer: computer, transportFactory: { transport })
    defer { agent.stop() }
    agent.send("Type")
    try await wait { transport.started }
    try await observe(transport)
    transport.action(.object(["action": .string("type"), "text": .string("marker")]))
    try await wait { agent.pendingApproval != nil }
    let id = try XCTUnwrap(agent.pendingApproval).id
    try await wait { agent.status == .paused }
    agent.approveAction(id: id)
    XCTAssertTrue(computer.actions.isEmpty)
    XCTAssertNil(agent.pendingApproval)
    XCTAssertFalse(computer.owned)
  }

  // Full control still cannot execute coordinates from an observation older than the local freshness limit.
  func testExpiredScreenCannotAuthorizeInput() async throws {
    let computer = SecurityComputer()
    computer.capturedAt = Date().addingTimeInterval(-61)
    let transport = SecurityTransport()
    let agent = AgentController(computer: computer, transportFactory: { transport })
    defer { agent.stop() }
    agent.setControlMode(.fullControl)
    agent.send("Type")
    try await wait { transport.started }
    try await observe(transport)
    transport.action(.object(["action": .string("type"), "text": .string("marker")]))
    try await wait { transport.responses.count == 2 }
    XCTAssertTrue(computer.actions.isEmpty)
    XCTAssertEqual(transport.responses.last?["success"].bool, false)
  }

  // Unique items, repeated deltas, and large completions must all fail closed within the same bounded store.
  func testTranscriptFloodsReleaseInput() async throws {
    for mode in 0..<3 {
      let computer = SecurityComputer()
      let transport = SecurityTransport()
      let agent = AgentController(computer: computer, transportFactory: { transport })
      defer { agent.stop() }
      agent.send("Inspect")
      try await wait { transport.started }
      switch mode {
      case 0:
        for index in 0..<1100 { transport.delta(id: "item-\(index)", text: "small") }
      case 1:
        for _ in 0..<80 { transport.delta(id: "same", text: String(repeating: "é", count: 512)) }
      default:
        transport.emit(
          "item/completed",
          [
            "item": .object([
              "id": .string("complete"), "type": .string("agentMessage"),
              "text": .string(
                String(repeating: "x", count: AgentTranscript.maximumMessageBytes + 1)),
            ])
          ])
      }
      XCTAssertEqual(agent.status, .failed)
      XCTAssertFalse(computer.owned)
      XCTAssertLessThanOrEqual(agent.messages.count, AgentTranscript.maximumMessages)
      XCTAssertTrue(
        agent.messages.allSatisfy { $0.text.utf8.count <= AgentTranscript.maximumMessageBytes })
    }
  }

  // Several individually valid messages must still respect the total UTF-8 budget.
  func testTranscriptTotalByteBudgetAndReplacementAccounting() throws {
    var transcript = AgentTranscript()
    try transcript.put(.init(id: "replace", kind: .assistant, text: "abc"))
    try transcript.put(.init(id: "replace", kind: .assistant, text: "x"))
    XCTAssertEqual(transcript.byteCount, "replacex".utf8.count)
    let text = String(repeating: "x", count: 60_000)
    for index in 0..<17 { try transcript.put(.init(id: "\(index)", kind: .assistant, text: text)) }
    XCTAssertThrowsError(try transcript.put(.init(id: "overflow", kind: .assistant, text: text)))
    XCTAssertLessThanOrEqual(transcript.byteCount, AgentTranscript.maximumTotalBytes)
  }

  // Test helpers wait on observable effects rather than assuming task scheduling order.
  private func observe(_ transport: SecurityTransport) async throws {
    let before = transport.responses.count
    transport.tool("comet_screen", .object([:]))
    try await wait { transport.responses.count > before }
  }
  private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<250 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Security fixture timed out")
    throw AgentError("Security fixture timed out")
  }
}

// This computer cannot send real HID input; its identity is mutable to simulate endpoint replacement.
@MainActor private final class SecurityComputer: AgentComputer {
  var available = true
  var identity = "A"
  var owned = false
  var actions: [AgentAction] = []
  var capturedAt = Date()
  func acquire() throws { owned = true }
  func release() { owned = false }
  func screen() async throws -> AgentScreen {
    AgentScreen(
      imageURL: "data:image/png;base64,", width: 100, height: 80, id: "screen",
      capturedAt: capturedAt)
  }
  func perform(_ action: AgentAction) async throws { actions.append(action) }
}

// Send production-shaped events directly to the controller, including deliberately invalid model behavior.
@MainActor private final class SecurityTransport: AgentTransport {
  var onEvent: ((JSONValue) -> Void)?
  var onClose: ((String) -> Void)?
  var started = false
  var threadStarts = 0
  var responses: [JSONValue] = []
  func start() throws { started = false }
  func close() {}
  func notify(_ method: String, _ params: JSONValue) throws {}
  func respond(id: JSONValue, result: JSONValue) throws { responses.append(result) }
  func reject(id: JSONValue, message: String) throws {}
  func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
    switch method {
    case "account/read": return .object(["requiresOpenaiAuth": .bool(false)])
    case "thread/start":
      threadStarts += 1
      return .object(["thread": .object(["id": .string("thread")])])
    case "turn/start":
      started = true
      return .object(["turn": .object(["id": .string("turn")])])
    case "turn/interrupt":
      emit(
        "turn/completed",
        ["turn": .object(["id": .string("turn"), "status": .string("interrupted")])])
      return .object([:])
    default: return .object([:])
    }
  }
  func tool(_ name: String, _ args: JSONValue) {
    onEvent?(
      .object([
        "id": .string(UUID().uuidString), "method": .string("item/tool/call"),
        "params": .object([
          "threadId": .string("thread"), "turnId": .string("turn"), "tool": .string(name),
          "arguments": args,
        ]),
      ]))
  }
  func action(_ args: JSONValue) {
    var object = args.object
    object["screenId"] = .string("screen")
    tool("comet_action", .object(object))
  }
  func emit(_ method: String, _ fields: [String: JSONValue]) {
    var params = fields
    params["threadId"] = .string("thread")
    params["turnId"] = .string("turn")
    onEvent?(.object(["method": .string(method), "params": .object(params)]))
  }
  func delta(id: String, text: String) {
    emit("item/agentMessage/delta", ["itemId": .string(id), "delta": .string(text)])
  }
}
