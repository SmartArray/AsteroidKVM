import Foundation

public struct AudioNotificationPreferences: Codable, Equatable, Sendable {
  public var enabled = false
  public var endpoint = ""
  public var alias = ""
  public var cooldownSeconds = 30.0
  public var thresholdDecibels = -40.0
  public init() {}

  public var cooldown: TimeInterval {
    cooldownSeconds.isFinite ? min(86400, max(1, cooldownSeconds)) : 30
  }
  public var threshold: Double {
    thresholdDecibels.isFinite ? min(-10, max(-60, thresholdDecibels)) : -40
  }

  // Keep arbitrary webhook paths and query tokens, but never accept embedded HTTP credentials.
  public var endpointURL: URL? {
    let text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: text),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil, components.fragment == nil,
      components.port.map({ (1...65535).contains($0) }) ?? true
    else { return nil }
    return components.url
  }
}

// One admission per cooldown, including failures, prevents a failing endpoint from causing a request storm.
public struct AudioNotificationGate {
  private var lastAttempt: TimeInterval?
  public init() {}

  public mutating func admit(level: Double, preferences: AudioNotificationPreferences,
    now: TimeInterval) -> Bool
  {
    guard preferences.enabled, preferences.endpointURL != nil,
      level.isFinite, level > 0, now.isFinite,
      20 * log10(level) >= preferences.threshold,
      lastAttempt.map({ now - $0 >= preferences.cooldown }) ?? true
    else { return false }
    lastAttempt = now
    return true
  }
}

public struct AudioWebhookPayload: Codable, Sendable {
  public struct KVM: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let alias: String
  }
  public struct Screenshot: Codable, Sendable {
    public let mimeType: String
    public let base64: String
    public let width: Int
    public let height: Int
    public init(jpeg: Data, width: Int, height: Int) {
      mimeType = "image/jpeg"
      base64 = jpeg.base64EncodedString()
      self.width = width
      self.height = height
    }
  }
  public let version: Int
  public let event: String
  public let timestamp: Date
  public let message: String
  public let kvm: KVM
  public let audioLevel: Double
  public let screenshot: Screenshot

  public init(profile: ConnectionProfile, level: Double, screenshot: Screenshot, timestamp: Date = Date(),
    isTest: Bool = false)
  {
    version = 1
    event = "audio_detected"
    self.timestamp = timestamp
    let alias = (profile.audioNotifications?.alias ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    kvm = KVM(id: profile.id, name: profile.name, alias: alias)
    let name = alias.isEmpty ? profile.name : alias
    message = isTest ? "Test notification from \(name)" : "Audio detected on \(name)"
    audioLevel = level
    self.screenshot = screenshot
  }

  public func data() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }
}

public struct AudioNotificationError: LocalizedError {
  public let description: String
  public init(_ description: String) { self.description = description }
  public var errorDescription: String? { description }
}

// A webhook gets only its explicit JSON payload, with no KVM cookies, credentials, or redirect forwarding.
public final class AudioWebhookClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let configuration: URLSessionConfiguration
  public init(configuration: URLSessionConfiguration = .ephemeral) {
    self.configuration = configuration
    super.init()
  }

  public func send(to url: URL, payload: AudioWebhookPayload) async throws {
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try payload.data()
    do {
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw AudioNotificationError("The webhook returned an invalid response.")
      }
      guard (200..<300).contains(http.statusCode) else {
        if http.statusCode == 401 || http.statusCode == 403 {
          throw AudioNotificationError("Webhook authentication rejected (HTTP \(http.statusCode)). Check the secret token in the webhook URL.")
        }
        throw AudioNotificationError("Webhook delivery failed (HTTP \(http.statusCode)).")
      }
    } catch is CancellationError { throw CancellationError() }
    catch let error as AudioNotificationError { throw error }
    catch {
      // Network errors may include a secret webhook URL; expose a bounded, credential-free message.
      throw AudioNotificationError("Could not reach the webhook. Check its address and network connection.")
    }
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void)
  {
    completionHandler(nil)
  }
}
