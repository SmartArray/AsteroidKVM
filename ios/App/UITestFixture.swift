#if DEBUG && targetEnvironment(simulator)
  // Deterministic UI tests use the production session, renderer and input queue without network access.
  import UIKit
  import CoreVideo
  import CometCore
  import CometMedia
  import CometSessionCore
  import WebRTC

  @MainActor func makeUITestSession() -> SessionCore {
    let session = SessionCore(
      profile: ConnectionProfile(name: "Simulator fixture", host: "fixture.invalid"))
    session.phase = .connected
    session.output = HIDOutput(
      send: { _ in }, paste: { _, _ in try await Task.sleep(for: .seconds(2)) })
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
