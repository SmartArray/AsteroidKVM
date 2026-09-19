import AppKit
import CometAgent
import CometCore
import CometMedia
import CometSession
import MetalKit
import WebRTC
// Run the production transport against a real local HTTP/WebSocket server, not stubbed API methods.
import XCTest

final class ProtocolE2ETests: XCTestCase {
  private var server: Process!
  private var port = 0
  override func setUpWithError() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["python3", root.appendingPathComponent("scripts/mock-comet.py").path]
    let pipe = Pipe()
    server.standardOutput = pipe
    server.standardError = FileHandle.nullDevice
    try server.run()
    let line = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    port = try XCTUnwrap(Int(line))
  }
  override func tearDownWithError() throws {
    server?.terminate()
    server?.waitUntilExit()
  }
  private func api() -> CometAPI {
    CometAPI(
      profile: ConnectionProfile(name: "Fixture", host: "127.0.0.1", port: port, scheme: "http"))
  }

  // Exercise authenticated multipart EDID uploads and byte-exact restoration through the production URLSession.
  func testEDIDReadApplyRestoreAndAuthentication() async throws {
    let service = api()
    do {
      _ = try await service.readEDID()
      XCTFail("EDID read accepted unauthenticated credentials")
    } catch { XCTAssertEqual(error as? CometError, .authentication) }
    try await service.login(password: "test-password")
    let empty = try await service.readEDID()
    XCTAssertNil(empty)
    let model = try await service.readDisplayModel()
    XCTAssertEqual(model, "RM1V2")
    let baseline = try EDIDPreset.fullHD.document()
    try await service.writeEDID(baseline)
    let alternative = try EDIDPreset.laptop.document()
    try await service.writeEDID(alternative)
    let readback = try await service.readEDID()
    XCTAssertEqual(readback, alternative)
    try await service.writeEDID(baseline)
    let restored = try await service.readEDID()
    XCTAssertEqual(restored, baseline)
    let state = try await service.call("/test/state")
    XCTAssertEqual(state["edid_writes"].number, 3)
    await service.close()
  }

  // Authentication expiry on one client must not clear the other client's cookies or connection state.
  func testAuthenticationDiscoveryConfigurationAndSessionIsolation() async throws {
    let a = api()
    let b = api()
    try await a.login(password: "test-password")
    try await b.login(password: "test-password")
    let state = try await a.discover()
    XCTAssertTrue(state.mappedText)
    XCTAssertEqual(state.availableKeymaps, ["en-us", "de"])
    let config = try await a.updateConfig(["mouse_polling": .number(16)])
    XCTAssertEqual(config["unowned"]["keep"].number, 42)
    XCTAssertEqual(config["mouse_polling"].number, 16)
    try await a.logout()
    do {
      try await a.call("/api/auth/check")
      XCTFail("Logged-out credentials must fail")
    } catch { XCTAssertEqual(error as? CometError, .authentication) }
    try await b.call("/api/auth/check")
    await a.close()
    await b.close()
  }

  // Actual WebSocket mapped replies and paste HTTP requests prove UTF-8 and query limits reach the server intact.
  @MainActor func testOrderedLiveHIDMappedTextAndUnicodePaste() async throws {
    let api = api()
    try await api.login(password: "test-password")
    let socket = try await api.socket("/api/ws")
    _ = try await socket.receive()
    let output = HIDOutput(
      send: { event in
        try await socket.send(.string(String(decoding: event.json.data(), as: UTF8.self)))
      }, paste: { text, keymap in try await api.paste(text, keymap: keymap) })
    var input = InputEngine()
    input.nativeLayout = true
    input.mappedTextSupported = true
    input.keymap = "de"
    output.enqueue(input.keyDown(code: "KeyL", characters: "@", modifiers: .option).events)
    await output.flush()
    let reply = try await socket.receive()
    guard case .string(let text) = reply else { return XCTFail("Expected mapped reply") }
    XCTAssertTrue(try JSONValue.decode(Data(text.utf8))["event"]["mapped"].bool == true)
    let pasted = String(repeating: "ä€", count: 600) + "\nsecond line"
    output.paste(pasted, keymap: "de")
    output.enqueue([.key("KeyV", true)])
    await output.flush()
    let state = try await api.call("/test/state")
    XCTAssertEqual(state["pastes"].array.count, 1)
    XCTAssertEqual(state["pastes"].array.first?["text"].string, pasted)
    XCTAssertEqual(
      state["pastes"].array.first?["limit"].array.first?.string, String(pasted.unicodeScalars.count)
    )
    XCTAssertFalse(state["events"].array.contains { $0["event"]["key"].string == "KeyV" })
    output.releaseAll()
    await output.flush()
    socket.cancel(with: .normalClosure, reason: nil)
    await api.close()
  }

  func testFailedAuthenticationAndOversizePasteHaveNoSideEffects() async throws {
    let api = api()
    do {
      try await api.login(password: "wrong")
      XCTFail("Wrong password accepted")
    } catch { XCTAssertEqual(error as? CometError, .authentication) }
    try await api.login(password: "test-password")
    do {
      try await api.paste(String(repeating: "x", count: 16_385), keymap: "de")
      XCTFail("Oversize paste accepted")
    } catch { XCTAssertEqual(error as? CometError, .pasteTooLong) }
    let state = try await api.call("/test/state")
    XCTAssertTrue(state["pastes"].array.isEmpty)
    await api.close()
  }
  // Run two production session controllers against sockets and verify focus, sleep, and logout isolation.
  @MainActor func testSessionFocusSleepWakeAndLogoutLifecycle() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
      profileStoreURL: directory.appendingPathComponent("profiles.json"),
      mediaFactory: { _, _ in FixtureMedia() })
    let profile = ConnectionProfile(name: "First", host: "127.0.0.1", port: port, scheme: "http")
    let secondProfile = ConnectionProfile(
      name: "Second", host: "127.0.0.1", port: port, scheme: "http")
    let a = model.createSession(profile: profile, password: "test-password")
    let b = model.createSession(profile: secondProfile, password: "test-password")
    a.connect()
    b.connect()
    try await waitUntil { a.active && b.active }

    // Reopening an already connected profile must reuse its authenticated socket and media connection.
    a.connect()
    XCTAssertTrue(a.active)
    XCTAssertEqual(a.mediaConnectionsStarted, 1)
    a.capture()
    XCTAssertTrue(a.captured)
    XCTAssertFalse(b.captured)
    a.output?.enqueue(a.input.keyDown(code: "KeyA", characters: "a", modifiers: []).events)
    await a.output?.flush()
    b.capture()
    XCTAssertFalse(a.captured)
    XCTAssertTrue(b.captured)
    await a.output?.flush()
    let events = try await a.api!.call("/test/state")["events"].array
    XCTAssertTrue(
      events.contains { $0["event"]["key"].string == "KeyA" && $0["event"]["state"].bool == false })
    a.suspend()
    try await waitUntil { a.phase == .reconnecting }
    XCTAssertFalse(a.captured)
    XCTAssertTrue(b.active)
    a.wake()
    try await waitUntil { a.active }
    XCTAssertFalse(a.captured)

    // A wedged outbound transport must still allow session closure, with the other connection unaffected.
    a.output?.stop()
    let stalled = HIDOutput(
      send: { _ in try await Task.sleep(for: .seconds(60)) }, paste: { _, _ in })
    a.output = stalled
    stalled.enqueue([.key("KeyA", true)])
    try await Task.sleep(for: .milliseconds(20))
    let closingStarted = Date()
    await a.disconnect(logout: true)
    XCTAssertLessThan(Date().timeIntervalSince(closingStarted), 4)
    XCTAssertEqual(a.phase, .disconnected)
    XCTAssertTrue(b.active)
    try await b.api!.call("/api/auth/check")
    await b.disconnect()
  }

  // Exercise authenticated Janus signaling, native H.264 encode/decode, ICE, and Metal together.
  @MainActor func testNativeWebRTCVideoEndToEndThroughJanusAndMetal() async throws {
    let api = api()
    try await api.login(password: "test-password")
    let sender = LocalWebRTCPeer()
    let offer = try await sender.offer()
    try await api.call(
      "/test/offer", method: "POST",
      body: JSONValue.object(["type": .string("offer"), "sdp": .string(offer)]).data(),
      contentType: "application/json")
    let mailbox = FrameMailbox()
    let media = JanusClient(api: api, mailbox: mailbox)
    defer {
      media.stop()
      sender.peer.close()
    }
    var mediaError: Error?
    media.onError = { mediaError = $0 }
    try await media.start(muted: true)
    let deadline = Date().addingTimeInterval(20)
    var answer: String?
    while answer == nil && Date() < deadline && mediaError == nil {
      answer = try await api.call("/test/state")["answer"]["sdp"].string
      try await Task.sleep(for: .milliseconds(20))
    }
    if let mediaError { throw mediaError }
    try await sender.peer.setRemoteDescription(
      RTCSessionDescription(type: .answer, sdp: try XCTUnwrap(answer)))
    let renderer = try MetalVideoRenderer(
      mailbox: mailbox, device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    let view = MTKView(
      frame: CGRect(x: 0, y: 0, width: 640, height: 360), device: MTLCreateSystemDefaultDevice())
    view.colorPixelFormat = .bgra8Unorm
    view.isPaused = true
    var candidatesAdded = 0
    var number = 0
    while mailbox.statistics().received < 90 && Date() < deadline && mediaError == nil {
      if number % 5 == 0 {
        let candidates = try await api.call("/test/state")["candidates"].array
        for candidate in candidates.dropFirst(candidatesAdded) {
          if let sdp = candidate["candidate"].string {
            try await sender.peer.add(
              RTCIceCandidate(
                sdp: sdp, sdpMLineIndex: Int32(candidate["sdpMLineIndex"].number ?? 0),
                sdpMid: candidate["sdpMid"].string))
          }
        }
        candidatesAdded = candidates.count
      }
      try sender.frame(number)
      renderer.draw(in: view)
      number += 1
      try await Task.sleep(for: .milliseconds(30))
    }
    renderer.draw(in: view)
    try await Task.sleep(for: .milliseconds(60))
    if let mediaError { throw mediaError }
    let metrics = mailbox.statistics()
    XCTAssertGreaterThanOrEqual(metrics.received, 60)
    XCTAssertGreaterThan(metrics.presented, 30)
    XCTAssertEqual(metrics.width, 640)
    XCTAssertEqual(metrics.height, 360)
    XCTAssertEqual(metrics.copied, 0, "H.264 CVPixelBuffers should share native Metal textures")
    print(
      "LOCAL_WEBRTC_METRICS received=\(metrics.received) presented=\(metrics.presented) receive_fps=\(metrics.receivedFPS) present_fps=\(metrics.presentedFPS) copies=\(metrics.copied) decoder=\(metrics.decoder) path=\(metrics.texturePath) rtt_ms=\(metrics.rttMilliseconds) gpu_ms=\(metrics.renderMilliseconds)"
    )
    await api.close()
  }

  // The agent's real subprocess reads native WebRTC frames and sends balanced input through the live Comet protocol.
  @MainActor func testAgentThroughNativeVideoAndCometHIDEndToEnd() async throws {
    let api = api()
    try await api.login(password: "test-password")
    let sender = LocalWebRTCPeer()
    let offer = try await sender.offer()
    try await api.call(
      "/test/offer", method: "POST",
      body: JSONValue.object(["type": .string("offer"), "sdp": .string(offer)]).data(),
      contentType: "application/json")
    let session = SessionController(
      profile: ConnectionProfile(
        name: "Agent fixture", host: "127.0.0.1", port: port, scheme: "http"),
      password: "test-password")
    session.connect()
    try await waitUntil { session.active }
    let deadline = Date().addingTimeInterval(15)
    var answer: String?
    while answer == nil && Date() < deadline {
      answer = try await api.call("/test/state")["answer"]["sdp"].string
      try await Task.sleep(for: .milliseconds(20))
    }
    try await sender.peer.setRemoteDescription(
      RTCSessionDescription(type: .answer, sdp: try XCTUnwrap(answer)))
    let frames = Task {
      var number = 0
      var candidatesAdded = 0
      while !Task.isCancelled {
        if number % 5 == 0 {
          let candidates = try await api.call("/test/state")["candidates"].array
          for candidate in candidates.dropFirst(candidatesAdded) {
            if let sdp = candidate["candidate"].string {
              try await sender.peer.add(
                RTCIceCandidate(
                  sdp: sdp,
                  sdpMLineIndex: Int32(candidate["sdpMLineIndex"].number ?? 0),
                  sdpMid: candidate["sdpMid"].string))
            }
          }
          candidatesAdded = candidates.count
        }
        try sender.frame(number)
        number += 1
        try await Task.sleep(for: .milliseconds(30))
      }
    }
    defer { frames.cancel() }
    try await waitUntil { session.mailbox.snapshot() != nil }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let adapter = SessionAgentComputer(session: session)
    let agent = AgentController(
      computer: adapter,
      transportFactory: {
        CodexTransport(
          executable: URL(fileURLWithPath: "/usr/bin/env"),
          arguments: ["python3", root.appendingPathComponent("scripts/mock-codex.py").path])
      })
    // The loopback appliance and synthetic peer explicitly authorize autonomous input for this acceptance test.
    agent.setControlMode(.fullControl)
    session.onAgentInterruption = { [weak agent] in agent?.pause() }
    defer {
      agent.stop()
      sender.peer.close()
    }
    agent.send("Create a poem about apples")
    try await waitUntil { agent.status == .idle || agent.status == .failed }
    XCTAssertEqual(agent.status, .idle, agent.detail)
    let events = try await api.call("/test/state")["events"].array
    let text = events.filter { $0["event_type"].string == "mapped_text" }.map {
      $0["event"]["text"].text
    }.joined()
    XCTAssertEqual(text, "Apples glow in morning light.")
    let buttons = events.filter { $0["event_type"].string == "mouse_button" }
    XCTAssertTrue(buttons.contains { $0["event"]["state"].bool == true })
    XCTAssertEqual(buttons.last?["event"]["state"].bool, false)
    XCTAssertFalse(session.agentOwnsInput)
    XCTAssertEqual(session.mediaConnectionsStarted, 1)

    // Manual capture interrupts active automation before the first human key can reach the remote session.
    agent.send("Create another poem")
    try await waitUntil { agent.actionCount == 2 || agent.status == .failed }
    session.capture()
    XCTAssertTrue(session.captured)
    XCTAssertFalse(session.agentOwnsInput)
    try await waitUntil { agent.canResume || agent.status == .failed }
    XCTAssertEqual(agent.status, .paused, agent.detail)
    let pausedCount = try await api.call("/test/state")["events"].array.filter {
      $0["event_type"].string == "mapped_text"
    }.count
    try await Task.sleep(for: .milliseconds(500))
    let finalCount = try await api.call("/test/state")["events"].array.filter {
      $0["event_type"].string == "mapped_text"
    }.count
    XCTAssertEqual(
      finalCount, pausedCount, "No further characters may be sent after manual takeover")
    agent.stop()
    await session.disconnect()
    await api.close()
  }

  // Dispatch actual AppKit events through the production surface; a controlled window avoids OS automation dependencies.
  @MainActor func testAppKitInputAndFullscreenReleaseWithoutMediaRestart() async throws {
    let media = FixtureMedia()
    let session = SessionController(
      profile: ConnectionProfile(name: "Surface", host: "127.0.0.1", port: port, scheme: "http"),
      password: "test-password", mediaFactory: { _, _ in media })
    session.connect()
    try await waitUntil { session.active }
    let surface = RemoteSurface(session: session)
    let window = FocusedFixtureWindow(
      contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.contentView = surface
    window.makeFirstResponder(surface)
    session.capture()
    let key = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "a",
        charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    surface.keyDown(with: key)
    await session.output?.flush()
    NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
    try await Task.sleep(for: .milliseconds(40))
    await session.output?.flush()
    XCTAssertFalse(session.captured)
    XCTAssertEqual(media.starts, 1)
    let events = try await session.api!.call("/test/state")["events"].array
    XCTAssertTrue(
      events.contains { $0["event"]["key"].string == "KeyA" && $0["event"]["state"].bool == true })
    XCTAssertTrue(
      events.contains { $0["event"]["key"].string == "KeyA" && $0["event"]["state"].bool == false })
    // The emergency shortcut must interrupt automation even when human capture is currently released.
    session.agentOwnsInput = true
    session.onAgentInterruption = { session.agentOwnsInput = false }
    let emergency = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [.control, .option, .command], timestamp: 2,
        windowNumber: window.windowNumber,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53
      ))
    surface.keyDown(with: emergency)
    XCTAssertFalse(session.agentOwnsInput)
    surface.teardown()
    window.contentView = nil
    await session.disconnect()
  }

  // Reproduce pointer exit before a drag and inspect the live outline above the production Metal surface.
  @MainActor func testOCRSelectionSurvivesPointerExitAndCancelsWithEscape() async throws {
    let session = SessionController(
      profile: ConnectionProfile(name: "Selection", host: "127.0.0.1", port: port, scheme: "http"),
      password: "test-password", mediaFactory: { _, _ in FixtureMedia() })
    session.connect()
    try await waitUntil { session.active }
    let surface = RemoteSurface(session: session)
    let window = FocusedFixtureWindow(
      contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.contentView = surface
    defer {
      surface.teardown()
      window.contentView = nil
    }

    // Feed a native buffer through the actual renderer to establish the same geometry as a received frame.
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault, 800, 600, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
          as CFDictionary, &pixelBuffer), kCVReturnSuccess)
    session.mailbox.renderFrame(
      RTCVideoFrame(
        buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixelBuffer)), rotation: ._0,
        timeStampNs: 1))
    surface.layoutSubtreeIfNeeded()
    let metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? MTKView }.first)
    metal.isPaused = true
    metal.draw()
    session.startOCR()
    surface.synchronize()
    XCTAssertTrue(session.ocrSelecting)
    XCTAssertFalse(session.captured)

    // Deliver window-space events through AppKit, including leaving before the first mouse press.
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
      try XCTUnwrap(
        NSEvent.mouseEvent(
          with: type, location: surface.convert(point, to: nil), modifierFlags: [], timestamp: 1,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
    }
    let crossing = try XCTUnwrap(
      NSEvent.enterExitEvent(
        with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
        userData: nil))
    surface.mouseExited(with: crossing)
    surface.mouseEntered(with: crossing)
    XCTAssertTrue(session.ocrSelecting, "Leaving and returning must preserve the armed tool")
    try surface.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 120, y: 80)))
    try surface.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 380, y: 230)))

    // The crop outline must remain transparent, correctly positioned, and above the video during layout.
    let outline = try XCTUnwrap(surface.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
    let expected = CGRect(x: 120, y: 80, width: 260, height: 150)
    XCTAssertEqual(outline.path?.boundingBoxOfPath, expected)
    XCTAssertEqual(outline.frame, surface.bounds)
    XCTAssertEqual(outline.fillColor?.alpha, 0)
    XCTAssertEqual(outline.strokeColor, NSColor.gray.cgColor)
    XCTAssertGreaterThan(outline.zPosition, try XCTUnwrap(metal.layer).zPosition)
    surface.layout()
    surface.mouseExited(with: crossing)
    XCTAssertTrue(session.ocrSelecting)
    XCTAssertEqual(outline.path?.boundingBoxOfPath, expected)

    // Escape clears both the published toggle and its overlay before the pending mouse release can send HID.
    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    surface.keyDown(with: escape)
    XCTAssertFalse(session.ocrSelecting)
    XCTAssertNil(outline.path)
    try surface.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 380, y: 230)))
    await session.output?.flush()
    let events = try await session.api!.call("/test/state")["events"].array
    XCTAssertFalse(events.contains { $0["event"]["state"].bool == true })
    XCTAssertFalse(session.ocrBusy)
    await session.disconnect()
  }

  // Wait on observable session state with a deadline instead of relying on fixed test sleeps.
  @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(12)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(condition(), "Session did not reach the expected phase before its deadline")
  }

}

// Media lifecycle substitution keeps these tests about session ownership; native rendering has separate real GPU tests.
@MainActor private final class FixtureMedia: MediaConnection {
  var onError: ((Error) -> Void)?
  var onConnected: (() -> Void)?
  var onFeatures: ((JSONValue) -> Void)?
  var starts = 0
  func start(microphone: Bool, muted: Bool) async throws {
    starts += 1
    onConnected?()
  }
  func setMuted(_ muted: Bool) {}
  func stop() {}
}

// A test window supplies deterministic focus while retaining AppKit's real responder and notification machinery.
@MainActor private final class FocusedFixtureWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
