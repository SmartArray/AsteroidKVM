import CometCore
import CometMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension MCPObservation {
  func perceptionFrame() async throws -> PerceptionFrame {
    let frame = frame
    let timestamp = capturedAt.timeIntervalSince1970
    return try await Task.detached(priority: .userInitiated) {
      let capture = Date()
      let context = CIContext(options: [.cacheIntermediates: false])
      let video = CIImage(cvPixelBuffer: frame.buffer)
      // KVM video is opaque even when a decoder leaves the BGRA alpha channel unset.
      let source = video.composited(
        over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: video.extent)
      )
      let width = Int(source.extent.width)
      let height = Int(source.extent.height)
      guard (1...8192).contains(width), (1...8192).contains(height), width * height <= 33_554_432,
        let image = context.createCGImage(source, from: source.extent)
      else { throw PerceptionError("INVALID_FRAME", "Could not capture the KVM frame.") }
      // Both JPEG and the fingerprint come from this same immutable CGImage, with top-left pixel order.
      var pixels = Data(count: width * height * 4)
      let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard
          let canvas = CGContext(
            data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
      }
      guard drawn else {
        throw PerceptionError("INVALID_FRAME", "Could not fingerprint the KVM frame.")
      }
      let captureMS = Date().timeIntervalSince(capture) * 1000
      let encode = Date()
      let data = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          data, UTType.jpeg.identifier as CFString, 1, nil)
      else {
        throw PerceptionError("INVALID_FRAME", "Could not encode the KVM frame.")
      }
      CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw PerceptionError("INVALID_FRAME", "Could not encode the KVM frame.")
      }
      return try PerceptionFrame(
        width: width, height: height, timestamp: timestamp, image: data as Data, pixels: pixels,
        captureMilliseconds: captureMS, encodeMilliseconds: Date().timeIntervalSince(encode) * 1000)
    }.value
  }
}
