import CryptoKit
// Encapsulate credentials, trust, HTTP operations, and authenticated sockets per device.
import Foundation
import Security

public enum CometError: LocalizedError, Equatable {
  case invalidAddress, authentication, connectionLimit
  case unsupported(String)
  case server(Int)
  case invalidResponse
  case certificate(String)
  case pasteTooLong
  public var errorDescription: String? {
    switch self {
    case .invalidAddress: return "Enter a valid hostname, port, and connection scheme."
    case .authentication: return "Authentication required. Sign in again to this Comet."
    case .connectionLimit:
      return "The Comet has reached its connection limit. Close another session and reconnect."
    case .unsupported(let message): return message
    case .server(let status): return "The Comet could not complete the request (HTTP \(status))."
    case .invalidResponse: return "The Comet returned an unexpected response."
    case .certificate(let fingerprint):
      return "This device’s certificate needs approval. SHA-256: \(fingerprint)"
    case .pasteTooLong:
      return
        "Paste is limited to 16,384 Unicode scalars per operation. Split this text into smaller selections."
    }
  }
}

// A private URLSession accepts only normal trust or an explicitly pinned certificate for this endpoint.
public final class DeviceTransport: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
  @unchecked Sendable
{
  public let profile: ConnectionProfile
  private let lock = NSLock()
  private var candidate: String?
  public lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20
    // Large slow pastes can take minutes; individual ordinary requests still keep a short deadline.
    configuration.timeoutIntervalForResource = 7200
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()
  public init(profile: ConnectionProfile) {
    self.profile = profile
    super.init()
  }
  public var untrustedFingerprint: String? {
    lock.lock()
    defer { lock.unlock() }
    return candidate
  }

  // Redirects must not carry the appliance's auth cookie to another origin or downgrade HTTPS.
  public func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let original = profile.baseURL
    let same =
      request.url?.host == original?.host && request.url?.scheme == original?.scheme
      && request.url?.port == original?.port
    completionHandler(same ? request : nil)
  }

  // Compare the leaf certificate fingerprint only within the saved device's host and port.
  public func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
      let trust = challenge.protectionSpace.serverTrust
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }
    if SecTrustEvaluateWithError(trust, nil) {
      completionHandler(.useCredential, URLCredential(trust: trust))
      return
    }
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
      let leaf = chain.first
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map {
      String(format: "%02x", $0)
    }.joined()
    let sameDevice =
      challenge.protectionSpace.host.lowercased() == profile.host.lowercased()
      && challenge.protectionSpace.port == profile.port
    if sameDevice && profile.certificateSHA256 == fingerprint {
      completionHandler(.useCredential, URLCredential(trust: trust))
    } else {
      lock.lock()
      candidate = fingerprint
      lock.unlock()
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
}

public actor CometAPI {
  public nonisolated let transport: DeviceTransport
  private var token: String?
  public init(profile: ConnectionProfile, token: String? = nil) {
    transport = DeviceTransport(profile: profile)
    self.token = token
  }

  // URLComponents safely escapes query values, including keymap names and preset parameters.
  public func request(
    _ path: String, method: String = "GET", query: [String: String] = [:], body: Data? = nil,
    contentType: String? = nil, timeout: TimeInterval = 20
  ) throws -> URLRequest {
    guard let base = transport.profile.baseURL,
      var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
    else { throw CometError.invalidAddress }
    components.path = path
    components.queryItems =
      query.isEmpty ? nil : query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
    guard let url = components.url else { throw CometError.invalidAddress }
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.httpMethod = method
    request.httpBody = body
    request.setValue("CometKVM/1.0 macOS", forHTTPHeaderField: "User-Agent")
    if let token {
      request.setValue("auth_token=\(token)", forHTTPHeaderField: "Cookie")
      request.setValue(token, forHTTPHeaderField: "Token")
    }
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    return request
  }

  // Never retry mutations automatically: paste and appliance operations can have partial effects.
  @discardableResult public func call(
    _ path: String, method: String = "GET", query: [String: String] = [:], body: Data? = nil,
    contentType: String? = nil, timeout: TimeInterval = 20
  ) async throws -> JSONValue {
    let request = try request(
      path, method: method, query: query, body: body, contentType: contentType, timeout: timeout)
    let data: Data
    let response: URLResponse
    do { (data, response) = try await transport.session.data(for: request) } catch {
      if let fingerprint = transport.untrustedFingerprint {
        throw CometError.certificate(fingerprint)
      }
      throw error
    }
    guard let http = response as? HTTPURLResponse else { throw CometError.invalidResponse }
    if [401, 403].contains(http.statusCode) { throw CometError.authentication }
    if [409, 429, 503].contains(http.statusCode) { throw CometError.connectionLimit }
    guard (200...299).contains(http.statusCode) else { throw CometError.server(http.statusCode) }
    if data.isEmpty { return .null }
    let envelope = try JSONValue.decode(data)
    guard envelope["ok"].bool != false else { throw CometError.invalidResponse }
    return envelope.object["result"] ?? envelope
  }

  // Store login tokens in this actor only; URLSession has no shared cookie or credential store.
  public func login(password: String, onApprovalRequired: (@Sendable () async -> Void)? = nil)
    async throws
  {
    var form = URLComponents()
    form.queryItems = [
      URLQueryItem(name: "user", value: transport.profile.username),
      URLQueryItem(name: "passwd", value: password),
    ]
    let body = Data(
      (form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    var result = try await call(
      "/api/auth/login", method: "POST", body: body,
      contentType: "application/x-www-form-urlencoded")
    // Keep the temporary approval token in memory while polling the documented completion endpoint.
    if result["two_step_required"].bool == true {
      guard let approvalToken = result["two_step_token"].string else {
        throw CometError.invalidResponse
      }
      await onApprovalRequired?()
      let deadline = Date().addingTimeInterval(min(180, result["expires_in"].number ?? 120))
      var approvalForm = URLComponents()
      approvalForm.queryItems = [URLQueryItem(name: "two_step_token", value: approvalToken)]
      while Date() < deadline {
        try await Task.sleep(for: .seconds(2))
        result = try await call(
          "/api/auth/two_step_complete", method: "POST",
          body: Data((approvalForm.percentEncodedQuery ?? "").utf8),
          contentType: "application/x-www-form-urlencoded")
        if result["token"].string != nil { break }
        guard result["status"].string == "pending" else { throw CometError.authentication }
      }
      guard result["token"].string != nil else { throw CometError.authentication }
    }
    token = result["token"].string
    try await call("/api/auth/check")
  }

  // Revoke only this API’s token and clear it locally even if the request fails.
  public func logout() async throws {
    defer { token = nil }
    try await call("/api/auth/logout", method: "POST")
  }

  // Invalidate this API’s private URLSession and its outstanding requests.
  public func close() { transport.session.invalidateAndCancel() }

  // Use the same scoped transport for live state/HID and signaling, including certificate policy.
  public func socket(_ path: String, protocols: [String] = [], query: [String: String] = [:]) throws
    -> URLSessionWebSocketTask
  {
    var req = try request(path, query: query)
    var c = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
    c.scheme = c.scheme == "https" ? "wss" : "ws"
    req.url = c.url
    if !protocols.isEmpty {
      req.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
    }
    let ws = transport.session.webSocketTask(with: req)
    ws.resume()
    return ws
  }

  // Discovery treats only absent optional endpoints as unsupported, not authentication or network errors.
  public func discover() async throws -> DeviceState {
    try await call("/api/auth/check")
    var state = DeviceState()
    state.keymaps = try await call("/api/hid/keymaps")
    state.hid = try await call("/api/hid")
    state.streamer = try await call("/api/streamer")
    state.config = try await optional("/api/system/get_config")["config"]
    state.system = try await optional("/api/system/get_param")
    state.functions = try await optional(
      "/api/system/otg_functions", query: ["wait_ready": "false"])
    state.hardware = try await optional("/api/system/capability")
    return state
  }

  // Treat documented missing endpoints as absent capabilities while propagating authentication failures.
  private func optional(_ path: String, query: [String: String] = [:]) async throws -> JSONValue {
    do { return try await call(path, query: query) } catch CometError.server(let status)
      where [404, 405, 501].contains(status)
    { return .null }
  }

  // Refresh and merge the whole object immediately before writing so unknown fields survive.
  public func updateConfig(_ changes: [String: JSONValue]) async throws -> JSONValue {
    let fresh = try await call("/api/system/get_config")["config"].object
    let updated = JSONValue.object(fresh.merging(changes) { _, new in new })
    return try await call(
      "/api/system/set_config", method: "POST", body: updated.data(),
      contentType: "application/json")["config"]
  }

  // Explicit scalar limits prevent the firmware's default 1024-character silent truncation.
  public func paste(_ text: String, keymap: String) async throws {
    let count = text.unicodeScalars.count
    guard count <= 16_384 else { throw CometError.pasteTooLong }
    guard count > 0 else { return }
    // The firmware's slow mode preserves modifier reports on hosts that lose transitions at its fast rate.
    try await call(
      "/api/hid/print", method: "POST",
      query: ["keymap": keymap, "limit": String(count), "slow": "true"],
      // Budget for modifier transitions at the daemon's 30 ms slow rate, without timing out valid long text.
      body: Data(text.utf8), contentType: "text/plain; charset=utf-8",
      timeout: max(60, Double(count) * 0.3 + 30))
  }
}
