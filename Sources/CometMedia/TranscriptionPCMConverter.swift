// Convert decoded connection audio to the transcription provider PCM format.
import AVFoundation
import CometCore

@MainActor public protocol TranscriptionAudioSource: AnyObject {
  func start() async throws -> AsyncThrowingStream<Data, Error>
  func stop()
}

// Convert on one serial queue; bounded delivery prevents a slow network from accumulating recorded audio.
final class TranscriptionPCMConverter {
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
  // A standalone conversion boundary lets tests feed real PCM buffers without requiring recording permission.
  func process(_ sample: CMSampleBuffer) {
    guard sample.isValid, let description = sample.formatDescription, sample.numSamples > 0 else { return }
    let inputFormat = AVAudioFormat(cmAudioFormatDescription: description)
    guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
        frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
    input.frameLength = input.frameCapacity
    guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
      frameCount: Int32(sample.numSamples), into: input.mutableAudioBufferList) == noErr else {
      continuation.finish(throwing: TranscriptionError("Could not read remote audio."))
      return
    }
    process(input)
  }

  func process(_ input: AVAudioPCMBuffer) {
    let inputFormat = input.format
    if converter?.inputFormat != inputFormat { converter = AVAudioConverter(from: inputFormat, to: format) }
    guard let converter,
      let output = AVAudioPCMBuffer(pcmFormat: format,
        frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 24000 / inputFormat.sampleRate + 32))
    else {
      continuation.finish(throwing: TranscriptionError("Unsupported remote audio format."))
      return
    }
    var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if supplied { status.pointee = .noDataNow; return nil }
      supplied = true
      status.pointee = .haveData
      return input
    }
    guard error == nil, let bytes = output.int16ChannelData else {
      continuation.finish(throwing: TranscriptionError("Could not convert remote audio."))
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
