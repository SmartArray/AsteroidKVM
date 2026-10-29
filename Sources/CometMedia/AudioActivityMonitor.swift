import AVFoundation
import Foundation
import WebRTC

// The track renderer receives decoded audio before playback gain; recording is explicitly opt-in.
public final class AudioActivityMonitor: NSObject, RTCAudioRenderer, @unchecked Sendable {
  private let lock = NSLock()
  private var peak = 0.0
  private var recordingSink: AudioRecordingSink?

  public func setRecordingSink(_ sink: AudioRecordingSink?) {
    lock.lock()
    recordingSink = sink
    lock.unlock()
  }

  public func render(pcmBuffer: AVAudioPCMBuffer) {
    lock.lock()
    let recording = recordingSink
    lock.unlock()
    recording?.render(pcmBuffer: pcmBuffer)
    let frames = Int(pcmBuffer.frameLength)
    let channels = Int(pcmBuffer.format.channelCount)
    guard frames > 0, channels > 0 else { return }
    let buffers = pcmBuffer.format.isInterleaved ? 1 : channels
    let samples = pcmBuffer.format.isInterleaved ? frames * channels : frames
    var energy = 0.0
    for channel in 0..<buffers {
      switch pcmBuffer.format.commonFormat {
      case .pcmFormatInt16:
        guard let data = pcmBuffer.int16ChannelData?[channel] else { return }
        for index in 0..<samples {
          let value = Double(data[index]) / 32768
          energy += value * value
        }
      case .pcmFormatFloat32:
        guard let data = pcmBuffer.floatChannelData?[channel] else { return }
        for index in 0..<samples { energy += Double(data[index]) * Double(data[index]) }
      default: return
      }
    }
    let level = sqrt(energy / Double(frames * channels))
    guard level.isFinite else { return }
    lock.lock()
    peak = max(peak, min(1, level))
    lock.unlock()
  }

  // Retain brief sounds between UI ticks, and never replay old activity on subsequent ticks.
  public func takeLevel() -> Double {
    lock.lock()
    defer { lock.unlock() }
    let result = peak
    peak = 0
    return result
  }
}
