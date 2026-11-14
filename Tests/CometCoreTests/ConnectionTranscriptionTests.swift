import AVFoundation
@testable import CometMedia
import XCTest

final class ConnectionTranscriptionTests: XCTestCase {
  // Exercise the same per-track monitor used for recording, with opposite signals in two sessions.
  @MainActor func testConnectionsStayIsolatedAndStoppingOneLeavesOtherAttached() async throws {
    let first = AudioActivityMonitor(), second = AudioActivityMonitor()
    var firstSink: ConnectionTranscriptionSink?, secondSink: ConnectionTranscriptionSink?
    let a = ConnectionAudioCapture { firstSink = $0; first.setTranscriptionSink($0) }
    let b = ConnectionAudioCapture { secondSink = $0; second.setTranscriptionSink($0) }
    let streamA = try await a.start(), streamB = try await b.start()
    defer { a.stop(); b.stop() }
    let receivedA = expectation(description: "positive audio from first connection")
    let receivedB = expectation(description: "negative audio from second connection")
    let readerA = Task {
      for try await chunk in streamA {
        XCTAssertEqual(chunk.count, 4800)
        XCTAssertGreaterThan(mean(chunk), 9000)
        receivedA.fulfill()
        break
      }
    }
    let readerB = Task {
      for try await chunk in streamB {
        XCTAssertEqual(chunk.count, 4800)
        XCTAssertLessThan(mean(chunk), -9000)
        receivedB.fulfill()
        break
      }
    }
    defer { readerA.cancel(); readerB.cancel() }
    first.render(pcmBuffer: buffer(value: 10000))
    second.render(pcmBuffer: buffer(value: -10000))
    await fulfillment(of: [receivedA, receivedB], timeout: 3)
    a.stop()
    XCTAssertNil(firstSink)
    XCTAssertNotNil(secondSink)
    // Repeated stops of an old capture must not detach a replacement capture.
    let replacement = ConnectionAudioCapture { firstSink = $0; first.setTranscriptionSink($0) }
    _ = try await replacement.start()
    a.stop()
    XCTAssertNotNil(firstSink)
    replacement.stop()
  }

  func testStoppedSinkDiscardsLateAudio() async throws {
    let pair = AsyncThrowingStream<Data, Error>.makeStream()
    let sink = ConnectionTranscriptionSink(continuation: pair.continuation)
    sink.stop()
    sink.render(pcmBuffer: buffer(value: 10000))
    var iterator = pair.stream.makeAsyncIterator()
    let next = try await iterator.next()
    XCTAssertNil(next)
  }

  func testInputQueueOverflowFailsVisibly() async throws {
    let pair = AsyncThrowingStream<Data, Error>.makeStream()
    let sink = ConnectionTranscriptionSink(continuation: pair.continuation, maxPendingBytes: 1)
    sink.render(pcmBuffer: buffer(value: 10000))
    do {
      for try await _ in pair.stream { XCTFail("Overflowed input must not be transmitted") }
      XCTFail("Expected an explicit overflow error")
    } catch { XCTAssertTrue(error.localizedDescription.contains("keep up")) }
  }

  private func buffer(value: Int16) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000,
      channels: 2, interleaved: true)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600)!
    buffer.frameLength = 9600
    for index in 0..<19200 { buffer.int16ChannelData![0][index] = value }
    return buffer
  }

  private func mean(_ data: Data) -> Double {
    let bytes = [UInt8](data)
    let samples = stride(from: 0, to: bytes.count, by: 2).map {
      Double(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8))
    }
    return samples.reduce(0, +) / Double(samples.count)
  }
}
