import AVFoundation
import CometMedia
import CometSession
import XCTest

final class AudioRecordingTests: XCTestCase {
  func testStartTimestampAndSafeConnectionFilename() {
    let date = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(AudioRecordingSink.filename(connectionName: "Office KVM", startedAt: date,
      timeZone: TimeZone(secondsFromGMT: 0)!), "Office KVM-1970-01-01_00-00-00-000.wav")
    let name = AudioRecordingSink.filename(connectionName: "../Office/KVM:\n", startedAt: date)
    XCTAssertFalse(name.contains("/"))
    XCTAssertFalse(name.contains(":"))
    XCTAssertFalse(name.contains("\n"))
    XCTAssertFalse(name.hasPrefix("."))
    XCTAssertTrue(AudioRecordingSink.filename(connectionName: "  ...  ", startedAt: date).hasPrefix("Connection-"))
    XCTAssertLessThan(AudioRecordingSink.filename(connectionName: String(repeating: "🎵", count: 200), startedAt: date).utf8.count, 255)
  }

  func testWAVPreservesPCMAndCopiesBorrowedBuffersUntilStop() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for common in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32] {
      for channels: AVAudioChannelCount in [1, 2] {
        for interleaved in [false, true] {
          let input = try buffer(common: common, channels: channels, interleaved: interleaved)
          let result = await withCheckedContinuation { continuation in
            let sink = AudioRecordingSink(directory: directory, connectionName: "PCM fixture", startedAt: Date()) {
              continuation.resume(returning: $0)
            }
            for _ in 0..<10 {
              fill(input, value: 0.25)
              sink.render(pcmBuffer: input)
              fill(input, value: -0.5)
            }
            sink.stop()
            sink.render(pcmBuffer: input)
          }
          XCTAssertNil(result.errorMessage)
          let url = try XCTUnwrap(result.url)
          let file = try AVAudioFile(forReading: url)
          XCTAssertEqual(file.fileFormat.sampleRate, 48000)
          XCTAssertEqual(file.fileFormat.channelCount, 2)
          XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 16)
          XCTAssertEqual(file.length, 4800)
          let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800))
          try file.read(into: output)
          for channel in 0..<2 {
            let samples = try XCTUnwrap(output.floatChannelData?[channel])
            for index in 0..<Int(output.frameLength) { XCTAssertEqual(samples[index], 0.25, accuracy: 0.0001) }
          }
          let data = try Data(contentsOf: url)
          XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
          XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        }
      }
    }
  }

  func testSampleRateAndChannelChangesDrainBeforeFinalization() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let mono = try buffer(rate: 44100, channels: 1, frames: 4410)
    let stereo = try buffer(frames: 4800)
    fill(mono, value: 0.25)
    fill(stereo, value: 0.5)
    let result = await withCheckedContinuation { continuation in
      let sink = AudioRecordingSink(directory: directory, connectionName: "Changing format", startedAt: Date()) {
        continuation.resume(returning: $0)
      }
      sink.render(pcmBuffer: mono)
      sink.render(pcmBuffer: stereo)
      sink.stop()
    }
    XCTAssertNil(result.errorMessage)
    let file = try AVAudioFile(forReading: XCTUnwrap(result.url))
    // Draining a rate converter preserves its filter tail (under 2 ms here), rather than clipping it.
    XCTAssertGreaterThanOrEqual(file.length, 9600)
    XCTAssertLessThanOrEqual(file.length, 9696)
    let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: output)
    XCTAssertEqual(output.floatChannelData![0][1000], 0.25, accuracy: 0.001)
    XCTAssertEqual(output.floatChannelData![1][7000], 0.5, accuracy: 0.001)
  }

  @MainActor func testControllerFinalizesUsesStartNameAndNeverOverwrites() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = AudioRecordingController(directory: directory)
    let start = Date(timeIntervalSince1970: 100)
    let input = try buffer()
    fill(input, value: 0.25)
    let sink = try XCTUnwrap(controller.start(connectionName: "Office KVM", at: start))
    sink.render(pcmBuffer: input)
    XCTAssertTrue(controller.isRecording)
    controller.stop()
    XCTAssertFalse(controller.isRecording)
    XCTAssertTrue(controller.isSaving)
    XCTAssertNil(controller.start(connectionName: "Do not overlap"))
    await controller.finish()
    XCTAssertFalse(controller.isSaving)
    XCTAssertNil(controller.lastError)
    let first = try XCTUnwrap(controller.lastSavedURL)
    XCTAssertEqual(first.lastPathComponent, AudioRecordingSink.filename(connectionName: "Office KVM", startedAt: start))
    let firstBytes = try Data(contentsOf: first)
    let second = try XCTUnwrap(controller.start(connectionName: "Office KVM", at: start))
    second.render(pcmBuffer: input)
    second.render(pcmBuffer: input)
    await controller.finish()
    let secondURL = try XCTUnwrap(controller.lastSavedURL)
    XCTAssertNotEqual(first, secondURL)
    XCTAssertTrue(secondURL.lastPathComponent.hasSuffix("-2.wav"))
    XCTAssertEqual(try Data(contentsOf: first), firstBytes)
    XCTAssertEqual(try AVAudioFile(forReading: secondURL).length, 960)
  }

  func testCreationFailureAndBoundedQueueReportErrors() async throws {
    let directory = temporaryDirectory()
    try Data([1, 2, 3]).write(to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let failure = await withCheckedContinuation { continuation in
      let sink = AudioRecordingSink(directory: directory, connectionName: "Blocked", startedAt: Date()) {
        continuation.resume(returning: $0)
      }
      sink.stop()
    }
    XCTAssertNil(failure.url)
    XCTAssertNotNil(failure.errorMessage)
    XCTAssertEqual(try Data(contentsOf: directory), Data([1, 2, 3]))
    let available = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: available) }
    let input = try buffer()
    let overflow = await withCheckedContinuation { continuation in
      let sink = AudioRecordingSink(directory: available, connectionName: "Bounded", startedAt: Date(), maxPendingBytes: 1) {
        continuation.resume(returning: $0)
      }
      sink.render(pcmBuffer: input)
      sink.stop()
    }
    XCTAssertNotNil(overflow.errorMessage)
    XCTAssertEqual(try AVAudioFile(forReading: XCTUnwrap(overflow.url)).length, 0)
  }

  @MainActor func testRecordingsRemainIndependentAcrossConnections() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = AudioRecordingController(directory: directory)
    let second = AudioRecordingController(directory: directory)
    let a = try XCTUnwrap(first.start(connectionName: "KVM A"))
    let b = try XCTUnwrap(second.start(connectionName: "KVM B"))
    let input = try buffer()
    fill(input, value: 0.25)
    a.render(pcmBuffer: input)
    b.render(pcmBuffer: input)
    await first.finish()
    XCTAssertTrue(second.isRecording)
    b.render(pcmBuffer: input)
    await second.finish()
    XCTAssertEqual(try AVAudioFile(forReading: XCTUnwrap(first.lastSavedURL)).length, 480)
    XCTAssertEqual(try AVAudioFile(forReading: XCTUnwrap(second.lastSavedURL)).length, 960)
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("AsteroidKVM-recording-test-\(UUID())")
  }

  private func buffer(common: AVAudioCommonFormat = .pcmFormatFloat32, rate: Double = 48000,
    channels: AVAudioChannelCount = 2, interleaved: Bool = false, frames: AVAudioFrameCount = 480) throws -> AVAudioPCMBuffer
  {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: common, sampleRate: rate, channels: channels, interleaved: interleaved))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    return buffer
  }

  private func fill(_ buffer: AVAudioPCMBuffer, value: Float) {
    let channels = Int(buffer.format.channelCount)
    for channel in 0..<(buffer.format.isInterleaved ? 1 : channels) {
      for sample in 0..<(Int(buffer.frameLength) * (buffer.format.isInterleaved ? channels : 1)) {
        buffer.floatChannelData?[channel][sample] = value
        buffer.int16ChannelData?[channel][sample] = Int16(value * 32768)
      }
    }
  }
}
