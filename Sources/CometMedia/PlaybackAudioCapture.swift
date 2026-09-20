// Copy only this application's playback through ScreenCaptureKit, leaving the audible output untouched.
import AVFoundation
import CometCore
import ScreenCaptureKit

@MainActor public protocol TranscriptionAudioSource: AnyObject {
  func start() async throws -> AsyncThrowingStream<Data, Error>
  func stop()
}

@MainActor public final class PlaybackAudioCapture: TranscriptionAudioSource {
  private var stream: SCStream?
  private var sink: PlaybackAudioSink?
  private var generation = UUID()
  public init() {}

  // Filter by PID, never by all system audio; no screen output or microphone capture is registered.
  public func start() async throws -> AsyncThrowingStream<Data, Error> {
    stop()
    let ticket = generation
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard generation == ticket else { throw CancellationError() }
    guard let display = content.displays.first,
      let app = content.applications.first(where: { $0.processID == ProcessInfo.processInfo.processIdentifier })
    else { throw TranscriptionError("Could not find AsteroidKVM audio. Keep its remote window open.") }
    let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
    let config = SCStreamConfiguration()
    config.capturesAudio = true
    config.excludesCurrentProcessAudio = false
    config.sampleRate = 48000
    config.channelCount = 1
    config.width = 2
    config.height = 2
    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(20))
    let sink = PlaybackAudioSink(continuation: pair.continuation)
    let stream = SCStream(filter: filter, configuration: config, delegate: sink)
    self.sink = sink
    self.stream = stream
    try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
    do {
      try await stream.startCapture()
      guard generation == ticket else {
        try? await stream.stopCapture()
        throw CancellationError()
      }
      return pair.stream
    } catch {
      if generation == ticket { stop() }
      throw error
    }
  }

  // Finish delivery synchronously so buffered audio cannot outlive an explicit stop or a device switch.
  public func stop() {
    generation = UUID()
    sink?.finish()
    sink = nil
    let closing = stream
    stream = nil
    if let closing { Task { try? await closing.stopCapture() } }
  }
}

// Convert on one serial queue; bounded delivery prevents a slow network from accumulating recorded audio.
final class PlaybackAudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
  let queue = DispatchQueue(label: "app.asteroidkvm.transcription.audio")
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private var converter: AVAudioConverter?
  private var pending = Data()
  private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000,
    channels: 1, interleaved: true)!

  init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
    self.continuation = continuation
  }

  // Closing the stream is thread-safe and causes later capture callbacks to discard their samples.
  func finish() { continuation.finish() }
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    continuation.finish(throwing: TranscriptionError("Audio capture stopped. Check macOS screen/audio recording permission."))
  }

  // ScreenCaptureKit supplies PCM buffers; AVAudioConverter resamples to the API's 24 kHz signed PCM16 format.
  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio else { return }
    process(sample)
  }

  // A standalone conversion boundary lets tests feed real PCM buffers without requiring recording permission.
  func process(_ sample: CMSampleBuffer) {
    guard sample.isValid, let description = sample.formatDescription, sample.numSamples > 0 else { return }
    let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
    guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
        frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
    input.frameLength = input.frameCapacity
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
      frameCount: Int32(sample.numSamples), into: input.mutableAudioBufferList) == noErr else {
      continuation.finish(throwing: TranscriptionError("Could not read playback audio."))
      return
    }
    if converter?.inputFormat != inputFormat { converter = AVAudioConverter(from: inputFormat, to: format) }
    guard let converter,
      let output = AVAudioPCMBuffer(pcmFormat: format,
        frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 24000 / inputFormat.sampleRate + 32))
    else { return }
    var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if supplied { status.pointee = .noDataNow; return nil }
      supplied = true
      status.pointee = .haveData
      return input
    }
    guard error == nil, let bytes = output.int16ChannelData else {
      continuation.finish(throwing: TranscriptionError("Could not convert playback audio."))
      return
    }
    pending.append(Data(bytes: bytes[0], count: Int(output.frameLength) * 2))
    while pending.count >= 4800 {
      let chunk = Data(pending.prefix(4800))
      pending.removeFirst(4800)
      if case .dropped = continuation.yield(chunk) {
        continuation.finish(throwing: TranscriptionError("Transcription cannot keep up with audio. Stop and retry."))
        return
      }
    }
  }
}
