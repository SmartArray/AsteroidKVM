import AppKit
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
    surface.teardown()
    window.contentView = nil
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
