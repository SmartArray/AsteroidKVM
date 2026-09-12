// Exercise TLS and redirect policy with actual URLSession traffic; no system trust settings or real credentials change.
import CometAgent
import CometCore
import XCTest

final class TransportSecurityTests: XCTestCase {
  // A self-signed endpoint is rejected by default, accepted only after its fingerprint is approved, and rejects mismatch.
  func testTLSCertificateExceptionAndMismatch() async throws {
    let fixture = try SecurityServer(tls: true)
    defer { fixture.close() }
    let untrusted = CometAPI(profile: fixture.profile)
    do {
      try await untrusted.call("/echo")
      XCTFail("Unapproved TLS certificate accepted")
    } catch { XCTAssertNotNil(untrusted.transport.untrustedFingerprint) }
    let fingerprint = try XCTUnwrap(untrusted.transport.untrustedFingerprint)
    await untrusted.close()
    var profile = fixture.profile
    profile.certificateSHA256 = fingerprint
    let approved = CometAPI(profile: profile, token: "synthetic-token")
    let reply = try await approved.call("/echo")
    XCTAssertEqual(reply["token"].string, "synthetic-token")
    await approved.close()
    profile.certificateSHA256 = String(repeating: "0", count: 64)
    let mismatched = CometAPI(profile: profile)
    do {
      try await mismatched.call("/echo")
      XCTFail("Mismatched certificate accepted")
    } catch { XCTAssertEqual(mismatched.transport.untrustedFingerprint, fingerprint) }
    await mismatched.close()
  }

  // A redirect may retain credentials only on the original origin; host changes, port changes, and downgrades stop.
  func testRedirectsDoNotForwardCredentialsAcrossOrigins() async throws {
    let first = try SecurityServer(tls: true)
    let second = try SecurityServer(tls: false)
    defer {
      first.close()
      second.close()
    }
    let discovery = CometAPI(profile: first.profile)
    _ = try? await discovery.call("/echo")
    var profile = first.profile
    profile.certificateSHA256 = try XCTUnwrap(discovery.transport.untrustedFingerprint)
    await discovery.close()
    let api = CometAPI(profile: profile, token: "synthetic-token")
    let same = try await api.call(
      "/redirect", query: ["target": first.profile.baseURL!.absoluteString + "/echo"])
    XCTAssertEqual(same["token"].string, "synthetic-token")
    XCTAssertEqual(same["cookie"].string, "auth_token=synthetic-token")
    for target in [
      "https://localhost:\(first.port)/echo",
      "https://127.0.0.1:\(second.port)/echo",
      "http://127.0.0.1:\(first.port)/echo",
      second.profile.baseURL!.absoluteString + "/echo",
    ] {
      do {
        try await api.call("/redirect", query: ["target": target])
        XCTFail("Cross-origin redirect followed: \(target)")
      } catch { XCTAssertEqual(error as? CometError, .server(302)) }
    }
    let sink = CometAPI(profile: second.profile)
    let state = try await sink.call("/state")
    XCTAssertEqual(state["echoes"].integer(), 0)
    await api.close()
    await sink.close()
  }

  // Invalid response IDs fail the real pipe transport rather than trapping or aliasing an outstanding request.
  @MainActor func testMalformedCodexResponseIDsFailClosed() async throws {
    for id in ["1e100", "1.5", "-1"] {
      let source =
        "import sys\nfor line in sys.stdin:\n print('{\"id\":' + '\(id)' + ',\"result\":{}}', flush=True)"
      let transport = CodexTransport(
        executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", source])
      try transport.start()
      do {
        _ = try await transport.request("initialize", .object([:]))
        XCTFail("Malformed response ID accepted")
      } catch {}
      transport.close()
    }
  }

  // Many tiny envelopes must not leave a backlog capable of invoking callbacks after Stop.
  @MainActor func testCodexEventFloodStopsAtLocalGate() async throws {
    let source =
      "import sys,json\nrequest=json.loads(sys.stdin.readline())\nprint(json.dumps({'id':request['id'],'result':{}}),flush=True)\nfor _ in range(10000):\n print('{\"method\":\"fixture/event\",\"params\":{}}',flush=True)"
    let transport = CodexTransport(
      executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", source])
    var count = 0
    transport.onEvent = { _ in
      count += 1
      if count == 50 { transport.close() }
    }
    try transport.start()
    _ = try await transport.request("initialize", .object([:]))
    for _ in 0..<200 where count < 50 { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(count, 50)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(count, 50)
    transport.close()
  }

  // An overlarge protocol line is rejected before JSON parsing and cancels the waiting request.
  @MainActor func testBlockedCodexWriterIsBoundedAndStopRemainsResponsive() async throws {
    let transport = CodexTransport(
      executable: URL(fileURLWithPath: "/usr/bin/python3"),
      arguments: ["-c", "import time; time.sleep(3)"])
    try transport.start()
    // Resource exhaustion must close the transport so the owning controller immediately releases input.
    var closed = false
    transport.onClose = { _ in closed = true }
    let result = JSONValue.string(String(repeating: "x", count: 5_000_000))
    try transport.respond(id: .string("first"), result: result)
    XCTAssertThrowsError(try transport.respond(id: .string("second"), result: result))
    XCTAssertTrue(closed)
    try await Task.sleep(for: .milliseconds(100))
    let started = Date()
    transport.close()
    XCTAssertLessThan(
      Date().timeIntervalSince(started), 1, "Stop must not wait for the pipe to drain")
  }

  // Oversized input terminates the pipe session rather than attempting to parse an unbounded envelope.
  @MainActor func testOversizedCodexEnvelopeFailsClosed() async throws {
    let source = "import sys\nsys.stdin.readline()\nprint('x'*2000000,flush=True)"
    let transport = CodexTransport(
      executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", source])
    try transport.start()
    do {
      _ = try await transport.request("initialize", .object([:]))
      XCTFail("Oversized envelope accepted")
    } catch {}
    transport.close()
  }
}

// Own an ephemeral loopback fixture and its generated private key; cleanup removes every test-created file.
private final class SecurityServer {
  let directory: URL
  let process: Process
  let port: Int
  let profile: ConnectionProfile

  init(tls: Bool) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    process = Process()
    do {
      var arguments = [
        "python3",
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
          .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "scripts/mock-security-server.py"
          ).path,
      ]
      if tls {
        // OpenSSL produces a disposable self-signed leaf; no trust anchor is added to macOS.
        let cert = directory.appendingPathComponent("cert.pem")
        let key = directory.appendingPathComponent("key.pem")
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        generator.arguments = [
          "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path,
          "-days", "1", "-subj", "/CN=127.0.0.1",
        ]
        generator.standardOutput = FileHandle.nullDevice
        generator.standardError = FileHandle.nullDevice
        try generator.run()
        generator.waitUntilExit()
        guard generator.terminationStatus == 0 else { throw CometError.invalidResponse }
        arguments += [cert.path, key.path]
      }
      let output = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = arguments
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let port = Int(line) else { throw CometError.invalidResponse }
      self.port = port
      profile = ConnectionProfile(
        name: "Security fixture", host: "127.0.0.1", port: port, scheme: tls ? "https" : "http")
    } catch {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  // Only the owned loopback process is terminated; this never affects application or hardware sessions.
  func close() {
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    try? FileManager.default.removeItem(at: directory)
  }
}
