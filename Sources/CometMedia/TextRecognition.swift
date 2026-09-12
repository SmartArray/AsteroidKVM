import CometCore
import CoreImage
// Convert only a user-requested stable frame and run Vision locally off the main actor.
import Foundation
import ImageIO
import Vision

public enum TextRecognition {

  // Ask Vision for installed recognition languages so Settings never advertises an unavailable model.
  public static func languages() throws -> [String] {
    try VNRecognizeTextRequest().supportedRecognitionLanguages()
  }

  // Recognize only the selected snapshot and deliver its result without moving live video through UI state.
  public static func recognize(frame: VideoFrame, crop: CGRect, languages: [String] = [])
    async throws -> String
  {
    try await Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let context = CIContext(options: [.cacheIntermediates: false])
      let full = CIImage(cvPixelBuffer: frame.buffer)
      let rect = CGRect(
        x: crop.minX, y: full.extent.height - crop.maxY, width: crop.width, height: crop.height
      ).intersection(full.extent)
      guard rect.width >= 2 && rect.height >= 2, let image = context.createCGImage(full, from: rect)
      else { throw CometError.unsupported("Select a larger area inside the remote display.") }
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      if !languages.isEmpty {
        request.recognitionLanguages = languages
      } else {
        request.automaticallyDetectsLanguage = true
      }
      let orientation: CGImagePropertyOrientation =
        frame.rotation == 90
        ? .right : frame.rotation == 180 ? .down : frame.rotation == 270 ? .left : .up
      try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
      try Task.checkCancellation()
      return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(
        separator: "\n") ?? ""
    }.value
  }
}
