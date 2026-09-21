// Keep transcript ordering and limits independent of audio capture, networking, and presentation.
import Foundation

public struct TranscriptSegment: Identifiable, Equatable {
  public let id: String
  public var text: String
  public var complete: Bool
  public let time: Date
}

public struct SessionTranscript {
  public private(set) var segments: [TranscriptSegment] = []
  public init() {}

  // Item creation/commit events establish chronology before out-of-order final transcripts arrive.
  public mutating func receive(_ event: JSONValue) throws {
    let type = event["type"].text
    guard type == "input_audio_buffer.committed"
      || type == "conversation.item.input_audio_transcription.delta"
      || type == "conversation.item.input_audio_transcription.completed" else { return }
    guard let id = event["item_id"].string, !id.isEmpty, id.utf8.count <= 256 else {
      throw TranscriptionError("Invalid transcription item received.")
    }
    if !segments.contains(where: { $0.id == id }) {
      guard segments.count < 10000 else {
        throw TranscriptionError("Transcript history is full. Clear it before starting again.")
      }
      let segment = TranscriptSegment(id: id, text: "", complete: false, time: Date())
      if let previous = event["previous_item_id"].string,
        let index = segments.firstIndex(where: { $0.id == previous }) {
        segments.insert(segment, at: index + 1)
      } else { segments.append(segment) }
    }
    guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
    var proposed = segments[index]
    if type.hasSuffix(".completed") {
      proposed.text = event["transcript"].text
      proposed.complete = true
    } else if type.hasSuffix(".delta"), !proposed.complete {
      proposed.text += event["delta"].text
    }
    guard proposed.text.utf8.count <= 65536,
      segments.reduce(0, { $0 + $1.text.utf8.count }) - segments[index].text.utf8.count
        + proposed.text.utf8.count <= 4 * 1024 * 1024 else {
      throw TranscriptionError("Transcript history is full. Clear it before starting again.")
    }
    segments[index] = proposed
  }
}

// Report actionable failures without exposing API credentials or raw server envelopes.
public struct TranscriptionError: LocalizedError {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

// Store the API key separately from appliance credentials and ordinary user preferences.
public enum TranscriptionCredentials {
  private static let profile = ConnectionProfile(name: "OpenAI", host: "api.openai.com")
  private static let store = PasswordStore(service: "app.asteroidkvm.openai-transcription")
  public static func read() throws -> String? { try store.password(for: profile) }

  // Reveal only the key family and final four characters so users can identify the saved Keychain entry safely.
  public static func fingerprint(_ key: String) -> String {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let family = trimmed.hasPrefix("sk-proj-") ? "sk-proj-…" : "sk-…"
    return family + String(trimmed.suffix(4))
  }

  public static func save(_ key: String) throws {
    try store.save(key.trimmingCharacters(in: .whitespacesAndNewlines), for: profile)
  }
  public static func remove() throws { try store.remove(for: profile) }
}
