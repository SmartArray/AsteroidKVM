import CometCore
import CometMedia
import CoreImage
import ImageIO
import MetalKit
import UniformTypeIdentifiers
// Opt-in hardware tests use the supplied session in memory and fail explicitly if its token is rejected.
import XCTest

final class HardwareE2ETests: XCTestCase {
  @MainActor func testRealCometAuthenticationStateHIDVideoAndRendering() async throws {
    guard let path = ProcessInfo.processInfo.environment["COMET_E2E_SESSION"] else {
      throw XCTSkip("Set COMET_E2E_SESSION to opt into real Comet hardware tests.")
    }
    let session = try JSONValue.decode(
      Data(contentsOf: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)))
    let raw = session["host"].text
    let url = try XCTUnwrap(URL(string: raw.contains("://") ? raw : "https://" + raw))
    var profile = ConnectionProfile(
      name: "Hardware E2E", host: try XCTUnwrap(url.host),
      port: url.port ?? (url.scheme == "http" ? 80 : 443), scheme: url.scheme ?? "https",
      username: session["username"].text)
    var api = CometAPI(profile: profile, token: session["token"].string)

    // Test-only trust inherits explicit authorization from the session file and pins the observed leaf.
    do { try await api.call("/api/auth/check") } catch CometError.certificate(let fingerprint)
      where session["insecure"].bool == true
    {
      await api.close()
      profile.certificateSHA256 = fingerprint
      api = CometAPI(profile: profile, token: session["token"].string)
    }
    let state = try await api.discover()
    XCTAssertFalse(state.availableKeymaps.isEmpty)
    let socket = try await api.socket("/api/ws", query: ["stream": "true"])
    let first = try await socket.receive()
    if case .string(let text) = first {
      XCTAssertNotNil(try JSONValue.decode(Data(text.utf8))["event_type"].string)
    }

    // A balanced Shift tap checks the live physical path without typing or launching remote commands.
    for event in [
      HIDEvent.key("ShiftLeft", true), HIDEvent.key("ShiftLeft", false), HIDEvent("ping", [:]),
    ] {
      try await socket.send(.string(String(decoding: event.json.data(), as: UTF8.self)))
    }
    let mailbox = FrameMailbox()
    let media = JanusClient(api: api, mailbox: mailbox)
    var mediaError: Error?
    media.onError = { mediaError = $0 }
    try await media.start(muted: true)
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try MetalVideoRenderer(mailbox: mailbox, device: device)
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 960, height: 540), device: device)
    view.colorPixelFormat = .bgra8Unorm
    view.isPaused = true
    let deadline = Date().addingTimeInterval(35)
    while Date() < deadline && mailbox.statistics().received < 600 && mediaError == nil {
      renderer.draw(in: view)
      try await Task.sleep(for: .milliseconds(16))
    }
    let videoMetrics = mailbox.statistics()

    // Typing requires an explicitly prepared scratch editor and uses the same engine and FIFO as the app.
    if ProcessInfo.processInfo.environment["COMET_E2E_TYPING"] == "1" {
      XCTAssertTrue(state.mappedText, "The supplied daemon must advertise mapped_text")
      XCTAssertTrue(state.availableKeymaps.contains("de"))
      // Unique screen markers prevent an earlier run's text from satisfying the returned-video assertions.
      let identifier = String(Int.random(in: 1000...9999))
      let mappedMarker = "COMET MAPPED " + identifier
      let pasteMarker = "COMET PASTE " + identifier
      let endMarker = "COMET END " + identifier
      let sample = mappedMarker + "\näöüÄÖÜß @ € [] {} \\ |"
      let mappedSample = sample.replacingOccurrences(of: "\n", with: "")
      let replyReader = Task { () throws -> [JSONValue] in
        var replies: [JSONValue] = []
        while replies.count < mappedSample.unicodeScalars.count {
          let message = try await socket.receive()
          let data: Data
          switch message {
          case .string(let text): data = Data(text.utf8)
          case .data(let bytes): data = bytes
          @unknown default: continue
          }
          let value = try JSONValue.decode(data)
          if value["event_type"].string == "mapped_text_result" { replies.append(value["event"]) }
        }
        return replies
      }
      let replyTimeout = Task {
        try await Task.sleep(for: .seconds(20))
        socket.cancel(with: .goingAway, reason: nil)
      }
      defer {
        replyTimeout.cancel()
        replyReader.cancel()
      }
      var input = InputEngine()
      input.nativeLayout = true
      input.mappedTextSupported = state.mappedText
      input.keymap = "de"
      let typingAPI = api
      let output = HIDOutput(
        send: { event in
          try await socket.send(.string(String(decoding: event.json.data(), as: UTF8.self)))
        }, paste: { text, keymap in try await typingAPI.paste(text, keymap: keymap) })
      var inputError: Error?
      output.onError = { inputError = $0 }
      for scalar in sample.unicodeScalars {
        if scalar == "\n" {
          output.enqueue(input.keyDown(code: "Enter", characters: "\r", modifiers: []).events)
          output.enqueue(input.keyUp(code: "Enter"))
          continue
        }
        output.enqueue(
          input.keyDown(code: "KeyL", characters: String(scalar), modifiers: .option).events)
        output.enqueue(input.keyUp(code: "KeyL"))
      }
      await output.flush()
      let replies = try await replyReader.value
      replyTimeout.cancel()
      XCTAssertEqual(replies.compactMap { $0["text"].string }.joined(), mappedSample)
      XCTAssertTrue(
        replies.allSatisfy { $0["mapped"].bool == true },
        "Every German scalar must map successfully")

      // Separate mapped typing from stock HTTP paste with a physical Return and verify both screen markers.
      output.enqueue(input.keyDown(code: "Enter", characters: "\r", modifiers: []).events)
      output.enqueue(input.keyUp(code: "Enter"))
      await output.flush()
      output.paste(pasteMarker + "\näöüÄÖÜß @ € [] {} \\ |\n" + endMarker + "\n", keymap: "de")
      await output.flush()
      output.releaseAll()
      await output.flush()
      output.stop()
      if let inputError { throw inputError }
      try await Task.sleep(for: .seconds(3))
      let frame = try XCTUnwrap(mailbox.snapshot())
      let recognized = try await TextRecognition.recognize(
        frame: frame, crop: CGRect(origin: .zero, size: frame.size), languages: ["de-DE", "en-US"])
      XCTAssertTrue(
        recognized.contains(mappedMarker), "Mapped input must appear in the remote editor")
      XCTAssertTrue(
        recognized.contains(pasteMarker), "HTTP paste must appear in the remote editor")
      XCTAssertTrue(recognized.contains(endMarker), "Multiline paste must complete")
      print(
        "HARDWARE_TYPING mapped_scalars=\(replies.count) all_mapped=\(replies.allSatisfy { $0["mapped"].bool == true }) screen_markers_verified=\(recognized.contains(mappedMarker) && recognized.contains(pasteMarker) && recognized.contains(endMarker))"
      )
    }

    // Save a frame only when explicitly requested for visual verification of the test machine.
    if let path = ProcessInfo.processInfo.environment["COMET_E2E_CAPTURE_PATH"],
      let frame = mailbox.snapshot(),
      let image = CIContext().createCGImage(
        CIImage(cvPixelBuffer: frame.buffer), from: CGRect(origin: .zero, size: frame.size)),
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    {
      CGImageDestinationAddImage(destination, image, nil)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    // Performance covers the continuously rendered sample, excluding the later input/OCR verification pause.
    let metrics = videoMetrics
    media.stop()
    socket.cancel(with: .normalClosure, reason: nil)
    await api.close()
    if let mediaError { throw mediaError }
    XCTAssertGreaterThan(metrics.received, 30, "Expected decoded frames from the actual Comet")
    XCTAssertGreaterThan(metrics.presented, 10, "Expected actual Metal presentation")
    XCTAssertGreaterThan(metrics.width, 0)
    XCTAssertGreaterThan(metrics.height, 0)
    print(
      "HARDWARE_METRICS frames=\(metrics.received) presented=\(metrics.presented) resolution=\(metrics.width)x\(metrics.height) received_fps=\(metrics.receivedFPS) presented_fps=\(metrics.presentedFPS) copies=\(metrics.copied) replaced=\(metrics.replaced) decoder=\(metrics.decoder) path=\(metrics.texturePath) bitrate=\(metrics.bitrate) rtt_ms=\(metrics.rttMilliseconds) gpu_ms=\(metrics.renderMilliseconds)"
    )
  }
}
