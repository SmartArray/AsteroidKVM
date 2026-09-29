// Application-owned perception API. Neither MCP consumers nor replacement parsers need OmniParser types.
import CryptoKit
import Foundation

public struct UIElementType: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public static let supported = Set([
    "unknown", "text", "button", "textfield", "textarea", "checkbox", "radio", "toggle", "dropdown",
    "menu", "menu_item", "tab", "link", "icon", "image", "card", "window", "dialog", "toolbar",
    "list", "list_item", "slider", "scrollbar",
  ])
  public init(from decoder: Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct UIElement: Codable, Sendable, Identifiable, Equatable {
  public var id: Int
  public var type: UIElementType
  public var text: String?
  public var description: String?
  public var bboxPx: [Int]
  public var bboxNorm: [Double]
  public var clickPoint: [Int]
  public var interactive: Bool
  public var confidence: Double?
  public var label: String?
  public var parentID: Int?
  public var labelFor: Int?
  public var children: [Int]?
  enum CodingKeys: String, CodingKey {
    case id, type, text, description, interactive, confidence, label, children
    case bboxPx = "bbox_px"
    case bboxNorm = "bbox_norm"
    case clickPoint = "click_point"
    case parentID = "parent_id"
    case labelFor = "label_for"
  }
}

public struct ParsedScreen: Codable, Sendable, Equatable {
  public var schemaVersion = 1
  public let frameID: String
  public let width: Int
  public let height: Int
  public let timestamp: Double
  public var elements: [UIElement]
  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case frameID = "frame_id"
    case width, height, timestamp, elements
  }
  public init(frame: PerceptionFrame, elements: [UIElement], frameID: String? = nil) {
    self.frameID = frameID ?? frame.id
    width = frame.width
    height = frame.height
    timestamp = frame.timestamp
    self.elements = elements
  }
}

public struct PerceptionFrame: Sendable {
  public let id: String
  public let width: Int
  public let height: Int
  public let timestamp: Double
  public let image: Data
  // Full-resolution RGBA fingerprint, never exposed to MCP. Preserves small local changes unlike a global thumbnail.
  public let pixels: Data
  public let captureMilliseconds: Double
  public let encodeMilliseconds: Double
  public init(
    width: Int, height: Int, timestamp: Double, image: Data, pixels: Data,
    captureMilliseconds: Double = 0, encodeMilliseconds: Double = 0
  ) throws {
    guard (1...8192).contains(width), (1...8192).contains(height), width * height <= 33_554_432,
      pixels.count == width * height * 4, !image.isEmpty, image.count <= 20 * 1024 * 1024,
      timestamp.isFinite
    else { throw PerceptionError("INVALID_FRAME", "Invalid screenshot dimensions or data.") }
    self.width = width
    self.height = height
    self.timestamp = timestamp
    self.image = image
    self.pixels = pixels
    id = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
    self.captureMilliseconds = captureMilliseconds
    self.encodeMilliseconds = encodeMilliseconds
  }
}

public struct ParserDetection: Codable, Sendable, Equatable {
  public var type: String
  public var bbox: [Double]
  public var text: String?
  public var description: String?
  public var interactive: Bool
  public var confidence: Double?
  public var metadata: [String: JSONValue]?
  public init(
    type: String, bbox: [Double], text: String? = nil, description: String? = nil,
    interactive: Bool, confidence: Double? = nil, metadata: [String: JSONValue]? = nil
  ) {
    self.type = type
    self.bbox = bbox
    self.text = text
    self.description = description
    self.interactive = interactive
    self.confidence = confidence
    self.metadata = metadata
  }
}

public struct ParserResponse: Codable, Sendable {
  public let schemaVersion: Int
  public let frameID: String
  public let width: Int
  public let height: Int
  public let detections: [ParserDetection]
  public let device: String
  public let model: String
  public let inferenceMilliseconds: Double
  public let decodeMilliseconds: Double
  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case frameID = "frame_id"
    case width, height, detections, device, model
    case inferenceMilliseconds = "inference_ms"
    case decodeMilliseconds = "decode_ms"
  }
  public init(
    frame: PerceptionFrame, detections: [ParserDetection], device: String = "cpu",
    model: String = "fixture"
  ) {
    schemaVersion = 1
    frameID = frame.id
    width = frame.width
    height = frame.height
    self.detections = detections
    self.device = device
    self.model = model
    inferenceMilliseconds = 0
    decodeMilliseconds = 0
  }
  public func validate(for frame: PerceptionFrame) throws {
    guard schemaVersion == 1, frameID == frame.id, width == frame.width, height == frame.height,
      detections.count <= 2000, ["cpu", "mps", "other"].contains(device), model.count <= 256,
      inferenceMilliseconds.isFinite, inferenceMilliseconds >= 0, decodeMilliseconds.isFinite,
      decodeMilliseconds >= 0
    else {
      throw PerceptionError(
        "INVALID_RESPONSE",
        "Parser response does not match the submitted screenshot or API version.")
    }
    for item in detections {
      guard !item.type.isEmpty, item.type.count <= 64, item.bbox.count == 4,
        item.bbox.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
        item.bbox[0] < item.bbox[2], item.bbox[1] < item.bbox[3],
        (item.text?.count ?? 0) <= 8192, (item.description?.count ?? 0) <= 8192,
        item.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true
      else {
        throw PerceptionError(
          "INVALID_RESPONSE", "Parser returned invalid element geometry or metadata.")
      }
    }
  }
}

public protocol UIParser: Sendable {
  func parse(frame: PerceptionFrame) async throws -> ParserResponse
  func checkAvailability() async throws
}
extension UIParser {
  public func checkAvailability() async throws {}
}

public struct PerceptionError: Error, LocalizedError, Sendable {
  public let code: String
  public let message: String
  public let expectedFrameID: String?
  public let currentFrameID: String?
  public init(_ code: String, _ message: String, expected: String? = nil, current: String? = nil) {
    self.code = code
    self.message = message
    expectedFrameID = expected
    currentFrameID = current
  }
  public var errorDescription: String? { message }
  public var json: JSONValue {
    var fields: [String: JSONValue] = ["error": .string(code), "message": .string(message)]
    if let expectedFrameID { fields["expected_frame_id"] = .string(expectedFrameID) }
    if let currentFrameID { fields["current_frame_id"] = .string(currentFrameID) }
    return .object(fields)
  }
}

public struct PerceptionSettings: Codable, Sendable, Equatable {
  public var enabled = false
  public var host = "127.0.0.1"
  public var port = 9120
  public var requestTimeout = 90.0
  public var preferredDevice = "auto"
  public var cacheThreshold = 0.01
  public var minimumConfidence = 0.05
  public var debugLogging = false
  public var settlingMilliseconds = 150
  public init() {}
  public func validatedURL(path: String) throws -> URL {
    guard ["127.0.0.1", "localhost"].contains(host), (1024...65535).contains(port),
      requestTimeout.isFinite, (1...110).contains(requestTimeout),
      cacheThreshold.isFinite, (0...0.05).contains(cacheThreshold),
      minimumConfidence.isFinite, (0...1).contains(minimumConfidence),
      ["auto", "cpu", "mps"].contains(preferredDevice), (0...2000).contains(settlingMilliseconds)
    else {
      throw PerceptionError(
        "INVALID_CONFIGURATION", "Use a loopback host and valid parser settings.")
    }
    return URL(string: "http://127.0.0.1:\(port)/\(path)")!
  }
}

public enum FrameComparison {
  // A changed 32px tile invalidates the whole parse, including a small popup or changed control label.
  public static func equivalent(_ a: PerceptionFrame, _ b: PerceptionFrame, threshold: Double)
    -> Bool
  {
    guard a.width == b.width, a.height == b.height else { return false }
    let limit = min(0.05, max(0, threshold))
    if a.pixels == b.pixels { return true }
    return a.pixels.withUnsafeBytes { (old: UnsafeRawBufferPointer) in
      b.pixels.withUnsafeBytes { (new: UnsafeRawBufferPointer) in
        for ty in stride(from: 0, to: a.height, by: 32) {
          for tx in stride(from: 0, to: a.width, by: 32) {
            var changed = 0
            let maxY = min(ty + 32, a.height)
            let maxX = min(tx + 32, a.width)
            let count = (maxY - ty) * (maxX - tx)
            for y in ty..<maxY {
              for x in tx..<maxX {
                let index = (y * a.width + x) * 4
                if (0..<3).contains(where: { abs(Int(old[index + $0]) - Int(new[index + $0])) > 8 })
                {
                  changed += 1
                }
              }
            }
            if Double(changed) / Double(count) > limit { return false }
          }
        }
        return true
      }
    }
  }
}
