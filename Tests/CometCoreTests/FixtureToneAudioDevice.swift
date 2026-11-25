import AudioToolbox
import Foundation
import WebRTC

// Generate PCM through the real ADM without opening a microphone or requiring recording permission.
final class FixtureToneAudioDevice: NSObject, RTCAudioDevice {
  let deviceInputSampleRate = 48000.0
  let deviceOutputSampleRate = 48000.0
  let inputIOBufferDuration = 0.01
  let outputIOBufferDuration = 0.01
  let inputNumberOfChannels = 1
  let outputNumberOfChannels = 1
  let inputLatency = 0.0
  let outputLatency = 0.0
  private(set) var isInitialized = false
  private(set) var isPlayoutInitialized = false
  private(set) var isRecordingInitialized = false
  private(set) var isPlaying = false
  private(set) var isRecording = false
  private var delegate: (any RTCAudioDeviceDelegate)?
  private var timer: DispatchSourceTimer?
  private var sampleIndex = 0

  func initialize(with delegate: any RTCAudioDeviceDelegate) -> Bool {
    self.delegate = delegate
    isInitialized = true
    return true
  }
  func terminateDevice() -> Bool {
    _ = stopRecording()
    delegate = nil
    isInitialized = false
    isPlayoutInitialized = false
    isRecordingInitialized = false
    return true
  }
  func initializePlayout() -> Bool { isPlayoutInitialized = true; return true }
  func initializeRecording() -> Bool { isRecordingInitialized = true; return true }
  func startPlayout() -> Bool { isPlaying = true; return true }
  func stopPlayout() -> Bool { isPlaying = false; return true }
  func startRecording() -> Bool {
    guard !isRecording, let delegate else { return true }
    isRecording = true
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "test.audio.tone"))
    timer.schedule(deadline: .now(), repeating: .milliseconds(10))
    timer.setEventHandler { [weak self] in
      delegate.dispatchAsync { [weak self] in self?.deliver() }
    }
    self.timer = timer
    timer.resume()
    return true
  }
  func stopRecording() -> Bool {
    isRecording = false
    timer?.cancel()
    timer = nil
    return true
  }

  // Device state and PCM delivery stay on the ADM's worker thread, including timer callbacks.
  private func deliver() {
    guard isRecording, let delegate else { return }
    var samples = (0..<480).map { offset in
      Int16(sin(Double(sampleIndex + offset) * 2 * .pi * 440 / 48000) * 12000)
    }
    var timestamp = AudioTimeStamp()
    timestamp.mSampleTime = Double(sampleIndex)
    timestamp.mFlags = .sampleTimeValid
    sampleIndex += samples.count
    var flags: AudioUnitRenderActionFlags = []
    samples.withUnsafeMutableBytes { bytes in
      var list = AudioBufferList(mNumberBuffers: 1,
        mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
      _ = delegate.deliverRecordedData(&flags, &timestamp, 0, 480, &list, nil, nil)
    }
  }
}
