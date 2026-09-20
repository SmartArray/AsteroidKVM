// Own one session's opt-in audio transmission and in-memory transcript independently of its windows.
import Combine
import CometCore
import CometMedia
import Foundation

@MainActor public final class TranscriptionController: ObservableObject {
  @Published public private(set) var active = false
  @Published public private(set) var status = "Transcription is off"
  @Published public private(set) var transcript = SessionTranscript()
  private let audioFactory: @MainActor () -> any TranscriptionAudioSource
  private let connectionFactory: @MainActor () -> any TranscriptionConnection
  private var audio: (any TranscriptionAudioSource)?
  private var connection: (any TranscriptionConnection)?
  private var writer: Task<Void, Never>?
  private var reader: Task<Void, Never>?
  private var generation = UUID()

  // Inject both boundaries for deterministic streaming, clear, and cancellation tests.
  public init(audioFactory: @escaping @MainActor () -> any TranscriptionAudioSource = { PlaybackAudioCapture() },
    connectionFactory: @escaping @MainActor () -> any TranscriptionConnection = { RealtimeTranscription() }) {
    self.audioFactory = audioFactory
    self.connectionFactory = connectionFactory
  }

  // A fresh UUID namespaces provider item IDs across restarts; only explicit starts may transmit audio.
  public func start(key: String, language: String = "") {
    guard !active else { return }
    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      status = "Add your OpenAI API key in Transcription settings."
      return
    }
    let ticket = UUID()
    generation = ticket
    active = true
    status = "Connecting to OpenAI…"
    let audio = audioFactory()
    let connection = connectionFactory()
    self.audio = audio
    self.connection = connection
    writer = Task { [weak self] in
      do {
        try await connection.connect(key: key, language: language)
        guard let self, generation == ticket else { return }
        status = "Starting audio capture…"
        let samples = try await audio.start()
        guard generation == ticket else { audio.stop(); return }
        status = "Listening…"
        reader = Task { [weak self] in
          do {
            while !Task.isCancelled {
              var event = try await connection.receive()
              guard let self, generation == ticket else { return }
              // Prefix both linkage fields so restarts cannot merge different utterances by accident.
              var object = event.object
              for field in ["item_id", "previous_item_id"] {
                if let id = object[field]?.string { object[field] = .string(ticket.uuidString + id) }
              }
              event = .object(object)
              try transcript.receive(event)
              if !transcript.segments.isEmpty { status = "Transcribing" }
            }
          } catch { self?.fail(error, ticket: ticket) }
        }
        for try await chunk in samples {
          guard generation == ticket, !Task.isCancelled else { return }
          try await connection.append(chunk)
        }
        if generation == ticket { stop(reason: "Audio capture ended") }
      } catch { self?.fail(error, ticket: ticket) }
    }
  }

  // Cancel before publishing stopped state so no queued provider event can refill cleared or stopped history.
  public func stop(reason: String = "Transcription is off") {
    generation = UUID()
    writer?.cancel()
    reader?.cancel()
    writer = nil
    reader = nil
    audio?.stop()
    connection?.close()
    audio = nil
    connection = nil
    active = false
    status = reason
  }

  // Clearing also stops the provider session, erasing its local context and rejecting in-flight transcript events.
  public func clear() {
    stop(reason: "History cleared · start transcription to continue")
    transcript = SessionTranscript()
  }

  // Surface capture failures separately from API errors without exposing raw response or credential data.
  private func fail(_ error: Error, ticket: UUID) {
    guard generation == ticket else { return }
    stop(reason: (error as? TranscriptionError)?.message
      ?? "Transcription stopped. Check the connection, API key, and macOS screen/audio recording permission.")
  }
}
