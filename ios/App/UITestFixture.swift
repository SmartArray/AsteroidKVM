#if DEBUG && targetEnvironment(simulator)
  // Deterministic UI tests use the production session, renderer and input queue without network access.
  import UIKit
  import CoreVideo
  import CometCore
  import CometMedia
  import CometSessionCore
  import WebRTC

  @MainActor enum UITestInputRecorder {
    static var events: [HIDEvent] = []
    static var text = ""
    static var suspensions = 0
    static func record(_ event: HIDEvent) { events.append(event) }
    static func recordText(_ value: String) { text += value }
    static var summary: String {
      let downs = events.filter { $0 == .button("left", true) }.count
      let ups = events.filter { $0 == .button("left", false) }.count
      let moves = events.filter { $0.type == "mouse_move" || $0.type == "mouse_relative" }.count
      let absolute = events.filter { $0.type == "mouse_move" }.count
      let relative = events.filter { $0.type == "mouse_relative" }.count
      let keys = events.filter { $0.type == "key" }.map {
        "\($0.payload["key"].string ?? ""):\($0.payload["state"].bool == true ? "down" : "up")"
      }.joined(separator: ",")
      return
        "leftDown=\(downs) leftUp=\(ups) moves=\(moves) absolute=\(absolute) relative=\(relative) suspensions=\(suspensions) keys=\(keys) text=\(text)"
    }
  }

  // Model signaling completing before the first new frame, without contacting a KVM.
  @MainActor func simulateUITestReconnect(_ session: SessionCore) {
    guard ProcessInfo.processInfo.environment["ASTEROID_UI_RECONNECT_DELAY"] == "1",
      let frame = session.mailbox.snapshot()
    else { return }
    session.mailbox.clear()
    session.phase = .connecting
    Task { @MainActor [weak session] in
      try? await Task.sleep(for: .seconds(3))
      guard let session, session.phase == .connecting else { return }
      session.phase = .connected
      try? await Task.sleep(for: .seconds(2))
      guard session.phase == .connected else { return }
      session.mailbox.renderFrame(
        RTCVideoFrame(
          buffer: RTCCVPixelBuffer(pixelBuffer: frame.buffer), rotation: ._0,
          timeStampNs: frame.timestamp + 1))
    }
  }

  @MainActor func makeUITestSession(profile: ConnectionProfile) -> SessionCore {
    UITestInputRecorder.events = []
    UITestInputRecorder.text = ""
    let session = SessionCore(profile: profile)
    session.phase = .connected
    session.output = HIDOutput(
      send: {
        // Model a slow socket so sheet dismissal cannot hide lost key releases.
        if $0.type == "key" { try await Task.sleep(for: .milliseconds(100)) }
        await UITestInputRecorder.record($0)
      },
      paste: { text, _ in
        await UITestInputRecorder.recordText(text)
        try await Task.sleep(for: .seconds(2))
      })
    session.output?.onPasteChanged = { [weak session] in session?.pasting = $0 }
    session.state.keymaps = .object([
      "keymaps": .object(["available": .array([.string("en-us")]), "default": .string("en-us")])
    ])
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    if let buffer {
      CVPixelBufferLockBaseAddress(buffer, [])
      if let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: 1280, height: 720, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
      {
        context.setFillColor(UIColor(red: 0.04, green: 0.05, blue: 0.12, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
        context.translateBy(x: 0, y: 720)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        ("AsteroidKVM\n\(profile.name)\nReady for your computer." as NSString).draw(
          at: CGPoint(x: 80, y: 160),
          withAttributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 44, weight: .medium),
            .foregroundColor: UIColor.white,
          ])
        UIGraphicsPopContext()
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      session.mailbox.renderFrame(
        RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1))
    }
    return session
  }
#endif
