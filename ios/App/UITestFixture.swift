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
    static func record(_ event: HIDEvent) { events.append(event) }
    static func recordText(_ value: String) { text += value }
    static var summary: String {
      let downs = events.filter { $0 == .button("left", true) }.count
      let ups = events.filter { $0 == .button("left", false) }.count
      let moves = events.filter { $0.type == "mouse_move" || $0.type == "mouse_relative" }.count
      let keys = events.filter { $0.type == "key" }.map {
        "\($0.payload["key"].string ?? ""):\($0.payload["state"].bool == true ? "down" : "up")"
      }.joined(separator: ",")
      return "leftDown=\(downs) leftUp=\(ups) moves=\(moves) keys=\(keys) text=\(text)"
    }
  }

  @MainActor func makeUITestSession() -> SessionCore {
    UITestInputRecorder.events = []
    UITestInputRecorder.text = ""
    let session = SessionCore(
      profile: ConnectionProfile(name: "Simulator fixture", host: "fixture.invalid"))
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
        ("AsteroidKVM\nLocal test screen\nReady for your computer." as NSString).draw(
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
