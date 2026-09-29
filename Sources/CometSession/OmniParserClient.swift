import CometCore
import Foundation
import os

public struct ParserHealth: Codable, Sendable {
  public let schemaVersion: Int
  public let alive: Bool
  public let modelsLoaded: Bool
  public let device: String
  public let preferredDevice: String
  public let model: String
  public let version: String?
  public let cpuFallback: Bool
  public let error: String?
  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case alive
    case modelsLoaded = "models_loaded"
    case device
    case preferredDevice = "preferred_device"
    case model, version
    case cpuFallback = "cpu_fallback"
    case error
  }
}

private final class ParserRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

public final class OmniParserClient: UIParser, @unchecked Sendable {
  private let settings: PerceptionSettings
  private let token: String
  private let session: URLSession
  public init(settings: PerceptionSettings, token: String, session: URLSession? = nil) {
    self.settings = settings
    self.token = token
    if let session {
      self.session = session
    } else {
      let config = URLSessionConfiguration.ephemeral
      config.httpCookieStorage = nil
      config.urlCredentialStorage = nil
      config.urlCache = nil
      config.connectionProxyDictionary = [:]
      config.timeoutIntervalForResource = settings.requestTimeout
      self.session = URLSession(
        configuration: config, delegate: ParserRedirectPolicy(), delegateQueue: nil)
    }
  }
  deinit { session.invalidateAndCancel() }
  private func request(_ path: String, image: Data? = nil) async throws -> Data {
    guard !token.isEmpty else {
      throw PerceptionError(
        "PARSER_UNAVAILABLE", "Set the local parser access token in Settings → Local UI Parsing.")
    }
    var request = URLRequest(url: try settings.validatedURL(path: path))
    request.timeoutInterval = settings.requestTimeout
    request.httpMethod = image == nil ? "GET" : "POST"
    request.httpBody = image
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(settings.preferredDevice, forHTTPHeaderField: "X-Preferred-Device")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if image != nil { request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type") }
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let response = response as? HTTPURLResponse else {
        throw PerceptionError("INVALID_RESPONSE", "Invalid local parser HTTP response.")
      }
      guard response.expectedContentLength <= 8 * 1024 * 1024 else {
        throw PerceptionError("INVALID_RESPONSE", "Parser response exceeded the size limit.")
      }
      var data = Data()
      for try await byte in bytes {
        if data.count >= 8 * 1024 * 1024 {
          throw PerceptionError("INVALID_RESPONSE", "Parser response exceeded the size limit.")
        }
        data.append(byte)
      }
      try Task.checkCancellation()
      guard response.statusCode == 200 else {
        let code = (try? JSONValue.decode(data))?["error"].string ?? "PARSER_UNAVAILABLE"
        let messages = [
          "DEVICE_MISMATCH":
            "Restart the local service with the preferred device selected in settings.",
          "PARSER_BUSY": "Local parser is processing another screenshot. Retry shortly.",
          "UNAUTHORIZED":
            "Local parser rejected its access token. Update Local UI Parsing settings.",
        ]
        throw PerceptionError(
          messages[code] == nil ? "PARSER_UNAVAILABLE" : code,
          messages[code]
            ?? "Local UI parsing is unavailable. Check service health and model setup; raw screen and HID tools still work."
        )
      }
      return data
    } catch is CancellationError { throw CancellationError() } catch let error as PerceptionError {
      throw error
    } catch {
      throw PerceptionError(
        "PARSER_UNAVAILABLE",
        "Cannot reach the local UI parser. Start the service and check Local UI Parsing settings. Raw screen and HID tools remain available."
      )
    }
  }
  public func parse(frame: PerceptionFrame) async throws -> ParserResponse {
    let data = try await request("parse", image: frame.image)
    let response: ParserResponse
    do { response = try JSONDecoder().decode(ParserResponse.self, from: data) } catch {
      throw PerceptionError(
        "INVALID_RESPONSE", "Local parser returned malformed JSON or an incompatible schema.")
    }
    try response.validate(for: frame)
    return response
  }
  public func checkAvailability() async throws {
    let status = try await health()
    guard status.alive, status.modelsLoaded else {
      throw PerceptionError(
        "PARSER_UNAVAILABLE", "Local parser models are not ready. Check service health and setup.")
    }
  }
  public func health() async throws -> ParserHealth {
    let data = try await request("health")
    guard let health = try? JSONDecoder().decode(ParserHealth.self, from: data),
      health.schemaVersion == 1,
      ["mps", "cpu", "other"].contains(health.device)
    else {
      throw PerceptionError("INVALID_RESPONSE", "Local parser health response is incompatible.")
    }
    return health
  }
}

public actor UIPerceptionStore {
  private let parser: any UIParser
  private let settings: PerceptionSettings
  private var normalizer = UIElementNormalizer()
  private var cached: (PerceptionFrame, ParsedScreen, ParserResponse)?
  private var parsing = false
  private var parseSequence = 0
  private var generation = UUID()
  private let log = Logger(subsystem: "app.asteroidkvm", category: "UI Perception")
  public init(parser: any UIParser, settings: PerceptionSettings) {
    self.parser = parser
    self.settings = settings
  }
  public func reset() {
    generation = UUID()
    cached = nil
    normalizer.reset()
  }
  public func elements(frame: PerceptionFrame, refresh: Bool = false) async throws -> ParsedScreen {
    let started = Date()
    guard !parsing else {
      throw PerceptionError("PARSER_BUSY", "A parse for this device is already running.")
    }
    parsing = true
    let ticket = generation
    defer { parsing = false }
    try await parser.checkAvailability()
    try Task.checkCancellation()
    guard ticket == generation else { throw CancellationError() }
    if !refresh, let cached,
      FrameComparison.equivalent(cached.0, frame, threshold: settings.cacheThreshold)
    {
      if settings.debugLogging {
        log.info(
          "cache=hit capture_ms=\(frame.captureMilliseconds) encode_ms=\(frame.encodeMilliseconds) total_ms=\(Date().timeIntervalSince(started) * 1000) device=\(cached.2.device, privacy: .public)"
        )
      }
      return cached.1  // Retain the ID of the exact image that was parsed, not the merely similar image.
    }
    let requested = Date()
    let response = try await parser.parse(frame: frame)
    let requestMS = Date().timeIntervalSince(requested) * 1000
    try Task.checkCancellation()
    guard ticket == generation else { throw CancellationError() }
    let processing = Date()
    let normalized = try normalizer.normalize(
      response, frame: frame, minimumConfidence: settings.minimumConfidence)
    parseSequence += 1
    let parsed = ParsedScreen(
      frame: frame, elements: normalized.elements,
      frameID: "\(frame.id):\(generation.uuidString):\(parseSequence)")
    let postMS = Date().timeIntervalSince(processing) * 1000
    cached = (frame, parsed, response)
    if settings.debugLogging {
      log.info(
        "cache=miss capture_ms=\(frame.captureMilliseconds) encode_ms=\(frame.encodeMilliseconds) decode_ms=\(response.decodeMilliseconds) request_ms=\(requestMS) inference_ms=\(response.inferenceMilliseconds) postprocess_ms=\(postMS) total_ms=\((Date().timeIntervalSince(started) * 1000) + frame.captureMilliseconds + frame.encodeMilliseconds) device=\(response.device, privacy: .public)"
      )
    }
    return parsed
  }
  public func validate(frameID: String, elementID: Int, current: PerceptionFrame) throws
    -> UIElement
  {
    guard let cached, cached.1.frameID == frameID,
      FrameComparison.equivalent(cached.0, current, threshold: min(settings.cacheThreshold, 0.01))
    else {
      self.cached = nil
      throw PerceptionError(
        "STALE_FRAME", "The screen changed. Call screen.elements again before acting.",
        expected: frameID, current: current.id)
    }
    guard let element = cached.1.elements.first(where: { $0.id == elementID }) else {
      throw PerceptionError("UNKNOWN_ELEMENT", "Element does not exist in this parsed frame.")
    }
    return element
  }
}
