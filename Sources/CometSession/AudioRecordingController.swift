import Combine
import CometMedia
import Foundation

@MainActor public final class AudioRecordingController: ObservableObject {
  @Published public private(set) var isRecording = false
  @Published public private(set) var isSaving = false
  @Published public private(set) var startedAt: Date?
  @Published public private(set) var lastSavedURL: URL?
  @Published public private(set) var lastError: String?
  public let directory: URL
  public var onFinished: (() -> Void)?
  private var sink: AudioRecordingSink?
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  public var activeSink: AudioRecordingSink? { isRecording ? sink : nil }

  public init(directory: URL? = nil) {
    self.directory = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AsteroidKVM Recordings", isDirectory: true)
  }

  public func start(connectionName: String, at date: Date = Date()) -> AudioRecordingSink? {
    guard sink == nil else { return nil }
    startedAt = date
    lastSavedURL = nil
    lastError = nil
    isRecording = true
    let sink = AudioRecordingSink(directory: directory, connectionName: connectionName, startedAt: date) { [weak self] result in
      Task { @MainActor in
        guard let self else { return }
        self.sink = nil
        self.isRecording = false
        self.isSaving = false
        self.lastSavedURL = result.url
        self.lastError = result.errorMessage
        self.onFinished?()
        let waiters = self.finishWaiters
        self.finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
      }
    }
    self.sink = sink
    return sink
  }

  public func stop() {
    guard let sink else { return }
    isRecording = false
    isSaving = true
    sink.stop()
  }

  // Quit and disconnect await queued writes and WAV header finalization before releasing the session.
  public func finish() async {
    stop()
    guard sink != nil else { return }
    await withCheckedContinuation { finishWaiters.append($0) }
  }
}
