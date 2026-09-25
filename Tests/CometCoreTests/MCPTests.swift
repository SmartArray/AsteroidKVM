import CometAgent
import CometCore
import CometMedia
import CoreVideo
import ImageIO
import WebRTC
import XCTest

@testable import CometSession

final class MCPTests: XCTestCase {
  @MainActor private func fixture(
    control: Bool = true, port: Int = Int.random(in: 20000...60000),
    token: String = UUID().uuidString
  ) -> (SessionController, DeviceMCPServer, String) {
    var profile = ConnectionProfile(name: "MCP Fixture", host: "fixture.invalid")
    var preferences = MCPPreferences()
    preferences.enabled = true
    preferences.allowControl = control
    preferences.port = port
    profile.mcp = preferences
    let session = SessionController(profile: profile)
    let server = DeviceMCPServer(session: session, testToken: token)
    session.mcpServer = server
    session.phase = .connected
    session.state.keymaps = .object(["mapped_text": .bool(true)])
    frame(session)
    server.configure()
    return (session, server, token)
  }
  @MainActor private func frame(
    _ session: SessionController, width: Int = 320, height: Int = 200, white: Bool = false
  ) {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(
      nil, width, height, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    guard let buffer else { return XCTFail("Pixel buffer unavailable") }
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer), white ? 255 : 0, CVPixelBufferGetDataSize(buffer))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    session.mailbox.renderFrame(
      RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 0))
  }
  @MainActor private func request(
    _ server: DeviceMCPServer, token: String, client: String? = nil, method: String,
    params: JSONValue = .object([:]), notification: Bool = false, extra: [String: String] = [:]
  ) async throws -> MCPHTTPResponse {
    var headers = [
      "host": URL(string: server.endpoint)!.host! + ":"
        + String(URL(string: server.endpoint)!.port!), "authorization": "Bearer \(token)",
      "content-type": "application/json", "accept": "application/json, text/event-stream",
    ]
    if let client { headers["mcp-session-id"] = client }
    headers.merge(extra) { _, new in new }
    var body: [String: JSONValue] = [
      "jsonrpc": .string("2.0"), "method": .string(method), "params": params,
    ]
    if !notification { body["id"] = .string(UUID().uuidString) }
    return await server.handle(
      MCPHTTPRequest(
        method: "POST", path: "/mcp", headers: headers, body: try JSONValue.object(body).data()))
  }
  @MainActor private func initialize(_ server: DeviceMCPServer, _ token: String) async throws
    -> String
  {
    let response = try await request(
      server, token: token, method: "initialize",
      params: .object([
        "protocolVersion": .string("2025-11-25"),
        "clientInfo": .object(["name": .string("Test Client")]),
      ]))
    let client = try XCTUnwrap(response.headers["Mcp-Session-Id"])
    let initialized = try await request(
      server, token: token, client: client, method: "notifications/initialized", notification: true)
    XCTAssertEqual(initialized.status, 202)
    return client
  }
  @MainActor private func call(
    _ server: DeviceMCPServer, _ token: String, _ client: String, _ name: String,
    _ args: [String: JSONValue] = [:]
  ) async throws -> JSONValue {
    let response = try await request(
      server, token: token, client: client, method: "tools/call",
      params: .object(["name": .string(name), "arguments": .object(args)]))
    return try JSONValue.decode(response.body)["result"]
  }
  private func text(_ result: JSONValue) throws -> JSONValue {
    try JSONValue.decode(Data(try XCTUnwrap(result["content"].array.first?["text"].string).utf8))
  }
  @MainActor private func screen(_ server: DeviceMCPServer, _ token: String, _ client: String)
    async throws -> String
  {
    try text(await call(server, token, client, "get_screen"))["frameId"].string!
  }

  func testHTTPFramingRejectsAmbiguousOrOversizeRequests() throws {
    let header = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:9101\r\nContent-Length: 2\r\n\r\n"
    XCTAssertNil(try MCPHTTPRequest.parse(Data((header + "{").utf8)))
    XCTAssertEqual(try MCPHTTPRequest.parse(Data((header + "{}").utf8))?.body, Data("{}".utf8))
    for bad in [
      header + "{}extra",
      header.replacingOccurrences(
        of: "Content-Length: 2", with: "Content-Length: 2\r\nContent-Length: 2") + "{}",
      header.replacingOccurrences(of: "Content-Length: 2", with: "Transfer-Encoding: chunked"),
      header.replacingOccurrences(of: "Content-Length: 2", with: "Content-Length: 2000000"),
    ] {
      XCTAssertThrowsError(try MCPHTTPRequest.parse(Data(bad.utf8)))
    }
  }

  @MainActor func testAuthenticationOriginIsolationAndReadOnly() async throws {
    let (a, first, tokenA) = fixture(control: false)
    let (b, second, tokenB) = fixture()
    defer {
      first.disable()
      second.disable()
      _ = a
      _ = b
    }
    let wrong = try await request(second, token: tokenA, method: "initialize")
    XCTAssertEqual(wrong.status, 401)
    let origin = try await request(
      first, token: tokenA, method: "initialize", extra: ["origin": "https://evil.example"])
    XCTAssertEqual(origin.status, 403)
    let host = try await request(
      first, token: tokenA, method: "initialize", extra: ["host": "evil.example"])
    XCTAssertEqual(host.status, 403)
    let client = try await initialize(first, tokenA)
    let cross = try await request(second, token: tokenB, client: client, method: "tools/list")
    XCTAssertEqual(cross.status, 404)
    let listing = try await request(first, token: tokenA, client: client, method: "tools/list")
    let tools = try JSONValue.decode(listing.body)["result"]["tools"].array.compactMap {
      $0["name"].string
    }
    XCTAssertTrue(tools.contains("read_text"))
    XCTAssertFalse(tools.contains("type_text"))
    let denied = try await call(
      first, tokenA, client, "type_text",
      ["text": .string("secret"), "frameId": .string("x"), "actionId": .string("1")])
    XCTAssertEqual(denied["isError"].bool, true)
    XCTAssertFalse(a.agentOwnsInput)
  }

  @MainActor func testScreenshotsCropsAndOCRCoordinates() async throws {
    let (session, server, token) = fixture(control: false)
    defer {
      server.disable()
      _ = session
    }
    let client = try await initialize(server, token)
    let region: JSONValue = .object([
      "x": .number(10), "y": .number(20), "width": .number(100), "height": .number(80),
    ])
    let shot = try await call(server, token, client, "get_screen", ["region": region])
    let metadata = try text(shot)
    XCTAssertEqual(metadata["width"].number, 320)
    XCTAssertEqual(metadata["region"], region)
    let data = try XCTUnwrap(Data(base64Encoded: shot["content"].array[1]["data"].string!))
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(image.width, 100)
    XCTAssertEqual(image.height, 80)
    let ocr = try await call(
      server, token, client, "read_text", ["frameId": metadata["frameId"], "region": region])
    XCTAssertEqual(ocr["isError"].bool, false)
    XCTAssertEqual(try text(ocr)["lines"].array.count, 0)
    XCTAssertFalse(session.agentOwnsInput)
  }

  @MainActor func testShortcutDeduplicationAndOwnership() async throws {
    let (session, server, token) = fixture()
    defer { server.disable() }
    let events = EventRecorder()
    session.output = HIDOutput(
      send: {
        await events.add(
          $0.type + ":" + $0.payload["key"].text + ":" + String($0.payload["state"].bool ?? false))
      }, paste: { _, _ in })
    let client = try await initialize(server, token)
    let other = try await initialize(server, token)
    let id = try await screen(server, token, client)
    let args: [String: JSONValue] = [
      "frameId": .string(id), "actionId": .string("shortcut"),
      "keys": .array(["ControlLeft", "AltLeft", "Delete"].map(JSONValue.string)),
    ]
    let result = try await call(server, token, client, "press_keys", args)
    XCTAssertEqual(result["isError"].bool, false)
    let duplicate = try await call(server, token, client, "press_keys", args)
    XCTAssertEqual(try text(duplicate)["duplicate"].bool, true)
    let sent = await events.values
    XCTAssertEqual(
      sent,
      [
        "key:ControlLeft:true", "key:AltLeft:true", "key:Delete:true", "key:Delete:false",
        "key:AltLeft:false", "key:ControlLeft:false",
      ])
    let otherScreen = try await screen(server, token, other)
    let blocked = try await call(
      server, token, other, "click",
      [
        "frameId": .string(otherScreen), "actionId": .string("click"), "x": .number(5),
        "y": .number(5),
      ])
    XCTAssertEqual(blocked["isError"].bool, true)
    let builtIn = SessionAgentComputer(session: session)
    XCTAssertThrowsError(try builtIn.acquire())
    builtIn.release()
    XCTAssertTrue(
      session.agentOwnsInput, "A failed competing acquire must not release MCP ownership")
    server.expireClients(now: Date().addingTimeInterval(31))
    XCTAssertFalse(session.agentOwnsInput)
    try builtIn.acquire()
    server.stopAutomation()
    XCTAssertTrue(session.agentOwnsInput, "MCP stop must not release the built-in agent's lease")
    builtIn.release()
  }

  @MainActor func testStopCancelsDragAndBalancesButtons() async throws {
    let (session, server, token) = fixture()
    defer { server.disable() }
    let events = EventRecorder()
    session.output = HIDOutput(
      send: { await events.add($0.type + ":" + String($0.payload["state"].bool ?? false)) },
      paste: { _, _ in })
    let client = try await initialize(server, token)
    let id = try await screen(server, token, client)
    let args: [String: JSONValue] = [
      "frameId": .string(id), "actionId": .string("drag"), "x": .number(10), "y": .number(10),
      "toX": .number(200), "toY": .number(100), "durationMs": .number(1000),
    ]
    let task = Task { try await self.call(server, token, client, "drag", args) }
    for _ in 0..<100 {
      if await events.values.contains("mouse_button:true") { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    _ = try await call(server, token, client, "stop")
    let result = try await task.value
    await session.output?.flush()
    XCTAssertEqual(result["isError"].bool, true)
    XCTAssertFalse(session.agentOwnsInput)
    let sent = await events.values
    XCTAssertTrue(sent.contains("mouse_button:true"))
    XCTAssertEqual(sent.last, "mouse_button:false")
    _ = try await call(server, token, client, "drag", args)
    let retried = await events.values
    XCTAssertEqual(sent, retried, "Interrupted action IDs must never replay")
  }

  @MainActor func testStaleGeometryManualTakeoverAndIdentityRevocation() async throws {
    let (session, server, token) = fixture()
    defer { server.disable() }
    session.output = HIDOutput(send: { _ in }, paste: { _, _ in })
    let client = try await initialize(server, token)
    let id = try await screen(server, token, client)
    frame(session, width: 640)
    let stale = try await call(
      server, token, client, "click",
      ["frameId": .string(id), "actionId": .string("stale"), "x": .number(10), "y": .number(10)])
    XCTAssertEqual(stale["isError"].bool, true)
    let fresh = try await screen(server, token, client)
    _ = try await call(
      server, token, client, "click",
      ["frameId": .string(fresh), "actionId": .string("fresh"), "x": .number(10), "y": .number(10)])
    XCTAssertTrue(session.agentOwnsInput)
    session.capture()
    XCTAssertFalse(session.agentOwnsInput)
    XCTAssertTrue(server.paused)
    session.updateProfile { $0.host = "another.invalid" }
    let revoked = try await request(server, token: token, client: client, method: "tools/list")
    XCTAssertEqual(revoked.status, 401)
    XCTAssertTrue(server.clients.isEmpty)
  }

  @MainActor func testWaitForVisualChangeAndTimeout() async throws {
    let (session, server, token) = fixture(control: false)
    defer { server.disable() }
    let client = try await initialize(server, token)
    let id = try await screen(server, token, client)
    let timeout = try await call(
      server, token, client, "wait_for_change", ["frameId": .string(id), "timeoutMs": .number(0)])
    let lastText = timeout["content"].array.last!["text"].string!
    XCTAssertEqual(try JSONValue.decode(Data(lastText.utf8))["changed"].bool, false)
    let nextID = try text(timeout)["frameId"]
    frame(session, white: true)
    let changed = try await call(
      server, token, client, "wait_for_change", ["frameId": nextID, "timeoutMs": .number(100)])
    XCTAssertEqual(
      try JSONValue.decode(Data(changed["content"].array.last!["text"].string!.utf8))["changed"]
        .bool, true)
  }

  @MainActor func testRealHTTPInitializeAndDelete() async throws {
    let (session, server, token) = fixture()
    defer {
      server.disable()
      _ = session
    }
    for _ in 0..<100 where server.status == "Starting…" {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(server.status, "Listening")
    var request = URLRequest(url: URL(string: server.endpoint)!)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = Data(
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"HTTP Test"}}}"#
        .utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    XCTAssertEqual(http.statusCode, 200)
    XCTAssertEqual(try JSONValue.decode(data)["result"]["protocolVersion"].string, "2025-11-25")
    let client = try XCTUnwrap(http.value(forHTTPHeaderField: "Mcp-Session-Id"))
    request.httpMethod = "DELETE"
    request.httpBody = nil
    request.setValue(client, forHTTPHeaderField: "Mcp-Session-Id")
    let (_, deleted) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((deleted as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertTrue(server.clients.isEmpty)
  }
}
