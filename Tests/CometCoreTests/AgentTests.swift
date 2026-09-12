// Test real stdio framing and the controller's lifecycle independently of nondeterministic model decisions.
import AppKit
import CometAgent
import CometCore
import XCTest

@MainActor final class AgentTests: XCTestCase {
  // A subprocess fixture exercises initialization, inherited-tool disabling, images, actions, and streamed Markdown.
  func testChatScreenActionLoopThroughRealProcess() async throws {
    let computer = FixtureComputer()
    let agent = AgentController(computer: computer, transportFactory: fixtureTransport)
    defer { agent.stop() }
    agent.send("Create a poem about apples")
    try await wait { agent.status == .idle || agent.status == .failed }
    XCTAssertEqual(agent.status, .idle, agent.detail)
    XCTAssertEqual(
      computer.actions,
      [.click(x: 25, y: 30, button: "left", count: 1), .type("Apples glow in morning light.")])
    XCTAssertEqual(computer.screens, 3)
    XCTAssertTrue(
      agent.messages.contains {
        $0.kind == .assistant && $0.text == "Created a **poem about apples**."
      })
    XCTAssertFalse(computer.owned)
  }

  // Pause cancels in-flight typing locally, waits for interruption, and resumes against a fresh observation.
  func testPauseResumeAndStopDuringAction() async throws {
    let computer = FixtureComputer()
    computer.delay = true
    let agent = AgentController(computer: computer, transportFactory: fixtureTransport)
    defer { agent.stop() }
    agent.send("Create a poem")
    try await wait { computer.actions.count == 1 || agent.status == .failed }
    XCTAssertEqual(agent.status, .running, agent.detail)
    agent.pause()
    XCTAssertFalse(computer.owned)
    try await wait { agent.canResume || agent.status == .failed }
    XCTAssertTrue(agent.canResume, agent.detail)
    let count = computer.actions.count
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(computer.actions.count, count)
    computer.delay = false
    agent.resume()
    try await wait { agent.status == .idle || agent.status == .failed }
    XCTAssertEqual(agent.status, .idle, agent.detail)
    XCTAssertEqual(computer.actions.count, 3)
    XCTAssertGreaterThanOrEqual(computer.screens, 4)
    agent.stop()
    XCTAssertFalse(computer.owned)
  }

  // Pausing before initialization must preserve the unsubmitted user prompt for the first resumed turn.
  func testPauseBeforeStartupPreservesPrompt() async throws {
    let computer = FixtureComputer()
    let agent = AgentController(computer: computer, transportFactory: fixtureTransport)
    defer { agent.stop() }
    agent.send("Read only: inspect this screen.")
    agent.pause()
    try await wait { agent.canResume }
    XCTAssertEqual(computer.screens, 0)
    agent.resume()
    try await wait { agent.status == .idle || agent.status == .failed }
    XCTAssertEqual(agent.status, .idle, agent.detail)
    XCTAssertTrue(
      computer.actions.allSatisfy {
        if case .wait = $0 { return true }
        return false
      })
    XCTAssertTrue(agent.messages.contains { $0.text == "Remote screen inspected." })
  }

  // Models cannot replay observations, click outside the image, send malformed keys, or enqueue oversized text.
  func testActionValidationRejectsStaleAndMalformedInput() throws {
    let screen = AgentScreen(imageURL: "", width: 100, height: 80, id: "fresh")
    for value: JSONValue in [
      .object([
        "screenId": .string("old"), "action": .string("click"), "x": .number(10), "y": .number(10),
      ]),
      .object([
        "screenId": .string("fresh"), "action": .string("click"), "x": .number(100),
        "y": .number(10),
      ]),
      .object([
        "screenId": .string("fresh"), "action": .string("click"), "x": .number(0.5),
        "y": .number(10),
      ]),
      .object([
        "screenId": .string("fresh"), "action": .string("key"), "keys": .array([.string("Shell")]),
      ]),
      .object([
        "screenId": .string("fresh"), "action": .string("type"),
        "text": .string(String(repeating: "x", count: 1001)),
      ]),
    ] { XCTAssertThrowsError(try AgentTool.parse(value, screen: screen)) }
  }

  // A missing executable fails visibly, releases ownership, and leaves the chat ready for a corrected retry.
  func testLaunchFailureReleasesControl() async throws {
    let computer = FixtureComputer()
    let agent = AgentController(
      computer: computer,
      transportFactory: {
        CodexTransport(executable: URL(fileURLWithPath: "/nonexistent/comet-codex"))
      })
    agent.send("Read screen")
    try await wait { agent.status == .failed }
    XCTAssertFalse(computer.owned)
    XCTAssertFalse(agent.messages.isEmpty)
  }

  // Use the installed CLI only when explicitly enabled; this checks the real provider's dynamic image/tool contract.
  func testInstalledCodexVisionAndDynamicToolEndToEnd() async throws {
    guard ProcessInfo.processInfo.environment["COMET_CODEX_E2E"] == "1" else {
      throw XCTSkip("Set COMET_CODEX_E2E=1 to exercise the installed Codex account and model.")
    }
    let computer = FixtureComputer()
    let agent = AgentController(computer: computer)
    defer { agent.stop() }
    agent.send(
      "This is an isolated test computer. Read comet_screen, then use comet_action to click at x=25,y=30, then use comet_action to type exactly 'Apples glow'. Read the resulting screen and report completion. These two actions are explicitly authorized; use only Comet tools."
    )
    try await wait(seconds: 180) { agent.status == .idle || agent.status == .failed }
    XCTAssertEqual(agent.status, .idle, agent.detail)
    XCTAssertTrue(
      computer.actions.contains(.click(x: 25, y: 30, button: "left", count: 1)),
      "\(agent.messages.map(\.text))")
    XCTAssertTrue(computer.actions.contains(.type("Apples glow")), "\(agent.messages.map(\.text))")
    XCTAssertGreaterThanOrEqual(computer.screens, 3)
  }

  // Use a script path derived from the test source, never a shell command containing user-controlled text.
  private func fixtureTransport() -> any AgentTransport {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    return CodexTransport(
      executable: URL(fileURLWithPath: "/usr/bin/env"),
      arguments: ["python3", root.appendingPathComponent("scripts/mock-codex.py").path])
  }
  private func wait(seconds: Double = 10, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(condition(), "Agent condition timed out")
  }
}

// A drawn scratch editor acts as a deterministic computer; actions cannot affect any real desktop.
@MainActor private final class FixtureComputer: AgentComputer {
  var available = true
  var owned = false
  var screens = 0
  var actions: [AgentAction] = []
  var delay = false
  func acquire() throws { owned = true }
  func release() { owned = false }
  func screen() async throws -> AgentScreen {
    guard owned else { throw CancellationError() }
    screens += 1
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 640, height: 400).fill()
    let typed = actions.compactMap { action -> String? in
      if case .type(let text) = action { return text }
      return nil
    }.joined()
    ("Scratch Editor — isolated test\n" + typed as NSString).draw(
      at: NSPoint(x: 20, y: 300),
      withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    return AgentScreen(
      imageURL: "data:image/png;base64," + data.base64EncodedString(), width: 640, height: 400,
      id: UUID().uuidString)
  }
  func perform(_ action: AgentAction) async throws {
    guard owned else { throw CancellationError() }
    actions.append(action)
    if delay { try await Task.sleep(for: .seconds(10)) }
    try Task.checkCancellation()
  }
}
