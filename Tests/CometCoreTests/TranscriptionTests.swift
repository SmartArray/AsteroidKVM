// Verify transcript streaming, native PCM conversion, real WebSocket framing, and cancellation boundaries.
import AVFoundation
import CometCore
@testable import CometMedia
import CometSession
import XCTest

final class TranscriptionTests: XCTestCase {
  // Late finalization must replace partial text in chronological order rather than append a duplicate sentence.
  func testTranscriptReorderedCompletionAndLateDelta() throws {
    var transcript = SessionTranscript()
    for event in [
      #"{"type":"input_audio_buffer.committed","item_id":"a"}"#,
      #"{"type":"input_audio_buffer.committed","item_id":"b","previous_item_id":"a"}"#,
      #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"Hel"}"#,
      #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":"Second"}"#,
      #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"Hello"}"#,
      #"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"ignored"}"#,
    ] { try transcript.receive(JSONValue.decode(Data(event.utf8))) }
    XCTAssertEqual(transcript.segments.map(\.text), ["Hello", "Second"])
    XCTAssertTrue(transcript.segments.allSatisfy(\.complete))
  }

  // Feed actual 48 kHz float PCM through the capture converter and production WebSocket into session history.
  @MainActor func testPCMToWebSocketToTranscriptEndToEndAndClear() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    server.arguments = ["python3", root.appendingPathComponent("scripts/mock-transcription.py").path]
    let pipe = Pipe()
    server.standardOutput = pipe
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer { server.terminate(); server.waitUntilExit() }
    let port = try XCTUnwrap(Int(String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)))
    let source = FixtureTranscriptionAudio()
    let controller = TranscriptionController(audioFactory: { source }, connectionFactory: {
      RealtimeTranscription(endpoint: URL(string: "ws://127.0.0.1:\(port)/realtime?intent=transcription")!)
    })
    defer { controller.stop() }
    controller.start(key: "fixture-key", language: "en")
    try await waitUntil { source.started }
    let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(20))
    let sink = PlaybackAudioSink(continuation: pair.continuation)
    for _ in 0..<4 { sink.process(try pcmSample()) }
    sink.finish()
    var chunks = 0
    for try await data in pair.stream {
      XCTAssertEqual(data.count, 4800)
      XCTAssertTrue(data.contains(where: { $0 != 0 }))
      source.continuation.yield(data)
      chunks += 1
    }
    XCTAssertGreaterThan(chunks, 0)
    try await waitUntil { controller.transcript.segments.filter(\.complete).count == 2 }
    XCTAssertEqual(controller.transcript.segments.map(\.text), ["Hello from remote audio.", "Second sentence."])
    XCTAssertTrue(controller.active)
    controller.clear()
    XCTAssertFalse(controller.active)
    XCTAssertTrue(source.stopped)
    XCTAssertTrue(controller.transcript.segments.isEmpty)
    source.continuation.yield(Data(repeating: 1, count: 4800))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(controller.transcript.segments.isEmpty)
  }

  // Reject missing credentials without requesting capture permission or starting network traffic.
  @MainActor func testMissingKeyDoesNotCapture() {
    let source = FixtureTranscriptionAudio()
    let controller = TranscriptionController(audioFactory: { source })
    controller.start(key: "")
    XCTAssertFalse(controller.active)
    XCTAssertFalse(source.started)
  }

  // A cancelled startup may still receive an acknowledgment; it must never start audio capture afterward.
  @MainActor func testStopDuringStartupDoesNotBeginCapture() async throws {
    let source = FixtureTranscriptionAudio()
    let transport = SlowTranscriptionConnection()
    let controller = TranscriptionController(audioFactory: { source }, connectionFactory: { transport })
    controller.start(key: "fixture-key")
    try await waitUntil { transport.started }
    controller.clear()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertFalse(source.started)
    XCTAssertTrue(transport.closed)
    XCTAssertTrue(controller.transcript.segments.isEmpty)
  }

  // A slow consumer gets an explicit failure instead of silently dropped audio or unbounded memory growth.
  func testCaptureBackpressureFailsAndTranscriptRejectsOversizedText() async throws {
    let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let sink = PlaybackAudioSink(continuation: pair.continuation)
    for _ in 0..<4 { sink.process(try pcmSample()) }
    var failed = false
    do { for try await _ in pair.stream {} } catch { failed = true }
    XCTAssertTrue(failed)
    var transcript = SessionTranscript()
    XCTAssertThrowsError(try transcript.receive(.object([
      "type": .string("conversation.item.input_audio_transcription.delta"),
      "item_id": .string("a"), "delta": .string(String(repeating: "a", count: 65537)),
    ])))
    XCTAssertEqual(transcript.segments.first?.text, "")
  }

  // Build a genuine CoreMedia sample with a known tone so the test catches silent or malformed PCM conversion.
  private func pcmSample() throws -> CMSampleBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    buffer.frameLength = 4800
    for index in 0..<4800 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.1) * 0.3) }
    var sample: CMSampleBuffer?
    XCTAssertEqual(CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault,
      dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
      formatDescription: format.formatDescription, sampleCount: 4800,
      presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample), noErr)
    let result = try XCTUnwrap(sample)
    XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result,
      blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: 0, bufferList: buffer.audioBufferList), noErr)
    CMSampleBufferSetDataReady(result)
    return result
  }

  // Keep asynchronous failures bounded and report the missing state transition instead of hanging the suite.
  @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw TranscriptionError("Timed out waiting for transcription fixture")
  }
}

// Intentionally ignore startup cancellation to reproduce an acknowledgment racing against Clear.
@MainActor private final class SlowTranscriptionConnection: TranscriptionConnection {
  var started = false
  var closed = false
  func connect(key: String, language: String) async throws {
    started = true
    try? await Task.sleep(for: .milliseconds(100))
  }
  func append(_ pcm: Data) async throws {}
  func receive() async throws -> JSONValue { throw CancellationError() }
  func close() { closed = true }
}

// A bounded PCM source replaces only OS permission/capture in protocol E2E; conversion and network remain production.
@MainActor private final class FixtureTranscriptionAudio: TranscriptionAudioSource {
  let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(20))
  var continuation: AsyncThrowingStream<Data, Error>.Continuation { pair.continuation }
  var started = false
  var stopped = false
  func start() async throws -> AsyncThrowingStream<Data, Error> { started = true; return pair.stream }
  func stop() { stopped = true; continuation.finish() }
}
