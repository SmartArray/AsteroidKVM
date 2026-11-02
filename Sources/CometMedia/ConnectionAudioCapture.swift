import AVFoundation
import CometCore
import Foundation

// Each activation attaches only to its session's decoded remote track, before playback gain.
@MainActor public final class ConnectionAudioCapture: TranscriptionAudioSource {
  private let attach: @MainActor (ConnectionTranscriptionSink?) -> Void
  private var sink: ConnectionTranscriptionSink?

  public init(attach: @escaping @MainActor (ConnectionTranscriptionSink?) -> Void) {
    self.attach = attach
  }

  public func start() async throws -> AsyncThrowingStream<Data, Error> {
    stop()
    try Task.checkCancellation()
    let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(20))
    let sink = ConnectionTranscriptionSink(continuation: pair.continuation)
    self.sink = sink
    attach(sink)
    return pair.stream
  }

  public func stop() {
    guard let sink else { return }
    sink.stop()
    self.sink = nil
    attach(nil)
  }
}

// WebRTC lends buffers only for the callback. Copy immediately, then resample off its audio thread.
public final class ConnectionTranscriptionSink: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "app.asteroidkvm.transcription.connection")
  private let processor: TranscriptionPCMConverter
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private var accepting = true
  private var pendingBytes = 0
  private let maxPendingBytes: Int

  init(continuation: AsyncThrowingStream<Data, Error>.Continuation, maxPendingBytes: Int = 1024 * 1024) {
    self.continuation = continuation
    self.maxPendingBytes = maxPendingBytes
    processor = TranscriptionPCMConverter(continuation: continuation)
  }

  public func stop() {
    lock.lock()
    accepting = false
    continuation.finish()
    lock.unlock()
  }

  public func render(pcmBuffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard accepting, pcmBuffer.frameLength > 0 else { return }
    let source = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
    let bytes = source.reduce(0) { $0 + Int($1.mDataByteSize) }
    guard bytes > 0 else { return }
    guard bytes <= maxPendingBytes - pendingBytes else {
      fail("Transcription cannot keep up with audio. Stop and retry.")
      return
    }
    guard let copy = AVAudioPCMBuffer(pcmFormat: pcmBuffer.format, frameCapacity: pcmBuffer.frameLength) else {
      fail("Could not copy remote audio.")
      return
    }
    copy.frameLength = pcmBuffer.frameLength
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard destination.count == source.count else { fail("Unsupported remote audio format."); return }
    for index in source.indices {
      guard let input = source[index].mData, let output = destination[index].mData,
        source[index].mDataByteSize <= destination[index].mDataByteSize else {
        fail("Could not read remote audio.")
        return
      }
      memcpy(output, input, Int(source[index].mDataByteSize))
    }
    pendingBytes += bytes
    queue.async { autoreleasepool {
      self.lock.lock()
      let active = self.accepting
      self.lock.unlock()
      if active { self.processor.process(copy) }
      self.lock.lock()
      self.pendingBytes -= bytes
      self.lock.unlock()
    } }
  }

  // Called with the admission lock held; a failed source cannot enqueue further audio.
  private func fail(_ message: String) {
    accepting = false
    continuation.finish(throwing: TranscriptionError(message))
  }
}
