import CometAgent
import CometCore
import CometMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

// MCP uses unrotated source pixels with a top-left origin. Crops retain this global coordinate space.
struct MCPObservation {
  let frame: VideoFrame
  let capturedAt: Date
  let screen: AgentScreen

  @MainActor static func capture(_ session: SessionController) throws -> MCPObservation {
    guard session.phase == .connected, session.state.online != false,
      session.mailbox.frameAge < 3, let frame = session.mailbox.snapshot()
    else {
      throw AgentError(
        "Device disconnected, no HDMI signal, or video is stale. Wait for live video.")
    }
    let time = Date().addingTimeInterval(-session.mailbox.frameAge)
    return MCPObservation(
      frame: frame, capturedAt: time,
      screen: AgentScreen(
        imageURL: "", width: Int(frame.size.width), height: Int(frame.size.height),
        id: UUID().uuidString, capturedAt: time))
  }

  func region(_ value: JSONValue) throws -> CGRect {
    let full = CGRect(origin: .zero, size: frame.size)
    if value == .null { return full }
    guard Set(value.object.keys) == ["x", "y", "width", "height"],
      let x = value["x"].integer(in: 0...(screen.width - 1)),
      let y = value["y"].integer(in: 0...(screen.height - 1)),
      let w = value["width"].integer(in: 2...max(2, screen.width)),
      let h = value["height"].integer(in: 2...max(2, screen.height))
    else { throw AgentError("Region requires integer x, y, width and height in source pixels.") }
    let rect = CGRect(x: x, y: y, width: w, height: h)
    guard full.contains(rect) else { throw AgentError("Region extends outside the screen.") }
    return rect
  }

  func image(region: CGRect) async throws -> JSONValue {
    let frame = frame
    let data = try await Task.detached(priority: .userInitiated) {
      let source = CIImage(cvPixelBuffer: frame.buffer)
      let rect = CGRect(
        x: region.minX, y: source.extent.height - region.maxY, width: region.width,
        height: region.height)
      let context = CIContext(options: [.cacheIntermediates: false])
      guard let image = context.createCGImage(source, from: rect) else {
        throw AgentError("Could not capture screen.")
      }
      let data = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          data, UTType.jpeg.identifier as CFString, 1, nil)
      else { throw AgentError("Could not encode screen.") }
      CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw AgentError("Could not encode screen.")
      }
      return (data as Data).base64EncodedString()
    }.value
    try Task.checkCancellation()
    return .object([
      "type": .string("image"), "mimeType": .string("image/jpeg"), "data": .string(data),
    ])
  }

  func metadata(region: CGRect) -> JSONValue {
    .object([
      "frameId": .string(screen.id), "width": .number(Double(screen.width)),
      "height": .number(Double(screen.height)),
      "capturedAt": .string(ISO8601DateFormatter().string(from: capturedAt)),
      "frameAgeMs": .number(max(0, Date().timeIntervalSince(capturedAt) * 1000)),
      "coordinateSystem": .string(
        "Unrotated source pixels, top-left origin. Add crop x/y to image-local coordinates. Actions always use full-screen coordinates."
      ),
      "region": .object([
        "x": .number(region.minX), "y": .number(region.minY), "width": .number(region.width),
        "height": .number(region.height),
      ]),
    ])
  }

  func sample(region: CGRect) async -> [UInt8] {
    let frame = frame
    return await Task.detached(priority: .utility) {
      let source = CIImage(cvPixelBuffer: frame.buffer)
      let rect = CGRect(
        x: region.minX, y: source.extent.height - region.maxY, width: region.width,
        height: region.height)
      let small = source.cropped(to: rect).transformed(
        by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
      )
      .transformed(by: CGAffineTransform(scaleX: 64 / rect.width, y: 64 / rect.height))
      var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
      bytes.withUnsafeMutableBytes { buffer in
        CIContext(options: [.cacheIntermediates: false]).render(
          small, toBitmap: buffer.baseAddress!, rowBytes: 64 * 4,
          bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBA8,
          colorSpace: CGColorSpaceCreateDeviceRGB())
      }
      return bytes
    }.value
  }

  func text(region: CGRect) async throws -> JSONValue {
    let frame = frame
    let result = try await Task.detached(priority: .userInitiated) {
      let source = CIImage(cvPixelBuffer: frame.buffer)
      let rect = CGRect(
        x: region.minX, y: source.extent.height - region.maxY, width: region.width,
        height: region.height)
      let context = CIContext(options: [.cacheIntermediates: false])
      guard let image = context.createCGImage(source, from: rect) else {
        throw AgentError("Could not crop screen.")
      }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.automaticallyDetectsLanguage = true
      try VNImageRequestHandler(cgImage: image).perform([request])
      return (request.results ?? []).compactMap { observation -> JSONValue? in
        guard let text = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return .object([
          "text": .string(text.string), "confidence": .number(Double(text.confidence)),
          "x": .number(region.minX + box.minX * region.width),
          "y": .number(region.minY + (1 - box.maxY) * region.height),
          "width": .number(box.width * region.width), "height": .number(box.height * region.height),
        ])
      }
    }.value
    try Task.checkCancellation()
    return .object([
      "frameId": .string(screen.id),
      "text": .string(result.compactMap { $0["text"].string }.joined(separator: "\n")),
      "lines": .array(result),
    ])
  }
}
