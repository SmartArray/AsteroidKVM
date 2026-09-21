// Isolate the OpenAI WebSocket protocol from session lifecycle and native audio capture.
import CometCore
import Foundation

@MainActor public protocol TranscriptionConnection: AnyObject {
  func connect(key: String, language: String) async throws
  func append(_ pcm: Data) async throws
  func receive() async throws -> JSONValue
  func close()
}

@MainActor public final class RealtimeTranscription: TranscriptionConnection {
  private var socket: URLSessionWebSocketTask?
  private var session: URLSession?
  private let endpoint: URL

  // Endpoint injection is limited to tests; the app always sends credentials to the fixed OpenAI endpoint.
  public init(endpoint: URL = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!) {
    self.endpoint = endpoint
  }

  // Wait for configuration acknowledgment before forwarding the first audio sample.
  public func connect(key: String, language: String) async throws {
    close()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20
    let session = URLSession(configuration: configuration, delegate: RejectTranscriptionRedirects(), delegateQueue: nil)
    self.session = session
    var request = URLRequest(url: endpoint)
    request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    let socket = session.webSocketTask(with: request)
    socket.maximumMessageSize = 128 * 1024
    self.socket = socket
    socket.resume()
    let deadline = Task {
      do { try await Task.sleep(for: .seconds(20)); socket.cancel(with: .goingAway, reason: nil) }
      catch {}
    }
    defer { deadline.cancel() }
    var transcription: [String: JSONValue] = ["model": .string("gpt-live-transcribe")]
    if !language.isEmpty { transcription["languages"] = .array([.string(language)]) }
    try await send(.object([
      "type": .string("session.update"),
      "session": .object([
        "type": .string("transcription"),
        "audio": .object(["input": .object([
          "format": .object(["type": .string("audio/pcm"), "rate": .number(24000)]),
          "transcription": .object(transcription),
          "turn_detection": .object(["type": .string("server_vad"), "silence_duration_ms": .number(500)]),
        ])]),
      ]),
    ]))
    for _ in 0..<20 {
      let event = try await receive()
      if event["type"].text == "session.updated" { return }
    }
    throw TranscriptionError("OpenAI did not confirm transcription settings.")
  }

  // Serialize one small PCM chunk at a time; the capture stream bounds pending audio to two seconds.
  public func append(_ pcm: Data) async throws {
    guard !pcm.isEmpty, pcm.count <= 48000 else { throw TranscriptionError("Invalid audio chunk.") }
    try await send(.object(["type": .string("input_audio_buffer.append"),
      "audio": .string(pcm.base64EncodedString())]))
  }

  // Bound sends so an unresponsive provider cannot retain an audio capture indefinitely.
  private func send(_ value: JSONValue) async throws {
    guard let socket else { throw CancellationError() }
    let deadline = Task {
      do { try await Task.sleep(for: .seconds(10)); socket.cancel(with: .goingAway, reason: nil) }
      catch {}
    }
    defer { deadline.cancel() }
    try await socket.send(.string(String(decoding: value.data(), as: UTF8.self)))
  }

  // Classify provider failures without echoing arbitrary server text, which could contain captured input.
  public func receive() async throws -> JSONValue {
    guard let socket else { throw CancellationError() }
    let message = try await socket.receive()
    let data: Data
    switch message {
    case .data(let bytes): data = bytes
    case .string(let string): data = Data(string.utf8)
    @unknown default: throw TranscriptionError("Unexpected transcription response.")
    }
    guard data.count <= 128 * 1024 else { throw TranscriptionError("Transcription response is too large.") }
    let event = try JSONValue.decode(data)
    if event["type"].text == "error" || event["type"].text.hasSuffix("transcription.failed") {
      throw TranscriptionError(Self.providerErrorMessage(event))
    }
    return event
  }

  // Turn known API error categories into useful guidance while retaining only safe code and field identifiers.
  static func providerErrorMessage(_ event: JSONValue) -> String {
    let error = event["error"]
    let code = safeIdentifier(error["code"].string)
    let type = safeIdentifier(error["type"].string)
    let field = safeIdentifier(error["param"].string)
    let classifier = [code, type, error["message"].string]
      .compactMap { $0?.lowercased() }.joined(separator: " ")
    let message: String
    if classifier.contains("invalid_api_key") || classifier.contains("incorrect api key")
      || classifier.contains("authentication") {
      message = "OpenAI rejected the saved API key. Replace it in Transcription settings."
    } else if classifier.contains("insufficient_quota") || classifier.contains("quota")
      || classifier.contains("credit") || classifier.contains("billing") {
      message = "OpenAI reports insufficient API quota. Check the key’s project budget and organization credits."
    } else if classifier.contains("rate_limit") || classifier.contains("rate limit") {
      message = "OpenAI rate-limited transcription. Wait briefly, then try again."
    } else if classifier.contains("permission") || classifier.contains("model_not_found")
      || classifier.contains("does not have access") {
      message = "This API key’s project cannot use gpt-live-transcribe. Check its model and endpoint permissions."
    } else if field != nil || classifier.contains("invalid_request")
      || classifier.contains("invalid_value") || classifier.contains("unknown_parameter") {
      message = "OpenAI rejected the transcription session configuration."
    } else {
      message = "OpenAI rejected transcription."
    }
    let details = [("code", code), ("type", type), ("field", field)]
      .compactMap { detail in detail.1.map { "\(detail.0): \($0)" } }
    return details.isEmpty ? message : message + " (" + details.joined(separator: ", ") + ")"
  }

  // Permit only short protocol identifiers in UI diagnostics; discard prose and control characters.
  private static func safeIdentifier(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= 160 else { return nil }
    let punctuation = Array("._-[]".utf8)
    guard value.utf8.allSatisfy({ byte in
      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        || punctuation.contains(byte)
    }) else { return nil }
    return value
  }

  // Invalidate all network work and discard ephemeral credential-bearing requests on stop.
  public func close() {
    socket?.cancel(with: .normalClosure, reason: nil)
    socket = nil
    session?.invalidateAndCancel()
    session = nil
  }
}

// Never follow a redirect with the transcription API key, including redirects to another OpenAI path.
private final class RejectTranscriptionRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
