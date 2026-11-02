import AVFoundation
import Darwin
import Foundation
import WebRTC

public struct AudioRecordingResult: Sendable {
  public let url: URL?
  public let errorMessage: String?
}

// Copy borrowed WebRTC buffers immediately; conversion and file I/O stay on a bounded serial queue.
public final class AudioRecordingSink: NSObject, RTCAudioRenderer, @unchecked Sendable {
  private let queue = DispatchQueue(label: "app.asteroidkvm.audio-recording", qos: .utility)
  private let lock = NSLock()
  private var accepting = true
  private var pendingBytes = 0
  private let maxPendingBytes: Int
  private let directory: URL
  private let filename: String
  private let completion: @Sendable (AudioRecordingResult) -> Void
  // Everything below is confined to queue.
  private var file: AVAudioFile?
  private var stagingURL: URL?
  private var converter: AVAudioConverter?
  private var framesWritten: UInt64 = 0
  private var finished = false
  private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000,
    channels: 2, interleaved: true)!

  public init(directory: URL, connectionName: String, startedAt: Date,
    maxPendingBytes: Int = 8 * 1024 * 1024,
    completion: @escaping @Sendable (AudioRecordingResult) -> Void)
  {
    self.directory = directory
    filename = Self.filename(connectionName: connectionName, startedAt: startedAt)
    self.maxPendingBytes = maxPendingBytes
    self.completion = completion
    super.init()
    queue.async { autoreleasepool {
      do { try self.prepare() }
      catch { self.finish(error: "Could not start audio recording: \(error.localizedDescription)") }
    } }
  }

  public static func filename(connectionName: String, startedAt: Date, timeZone: TimeZone = .current) -> String {
    let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
    let cleaned = String(String.UnicodeScalarView(connectionName.unicodeScalars.map {
      forbidden.contains($0) ? UnicodeScalar("-") : $0
    })).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    var name = ""
    for character in cleaned {
      guard name.utf8.count + String(character).utf8.count <= 160 else { break }
      name.append(character)
    }
    if name.isEmpty { name = "Connection" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
    return "\(name)-\(formatter.string(from: startedAt)).wav"
  }

  public func render(pcmBuffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard accepting, pcmBuffer.frameLength > 0 else { return }
    let source = UnsafeMutableAudioBufferListPointer(pcmBuffer.mutableAudioBufferList)
    let bytes = source.reduce(0) { $0 + Int($1.mDataByteSize) }
    guard bytes > 0 else { return }
    guard bytes <= maxPendingBytes - pendingBytes else {
      stopLocked(error: "The disk could not keep up with recording. Audio captured so far was saved.")
      return
    }
    guard let copy = AVAudioPCMBuffer(pcmFormat: pcmBuffer.format, frameCapacity: pcmBuffer.frameLength) else {
      stopLocked(error: "Could not copy incoming audio for recording.")
      return
    }
    copy.frameLength = pcmBuffer.frameLength
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    guard destination.count == source.count else {
      stopLocked(error: "The incoming audio format could not be recorded.")
      return
    }
    for index in source.indices {
      guard let input = source[index].mData, let output = destination[index].mData,
        source[index].mDataByteSize <= destination[index].mDataByteSize else {
        stopLocked(error: "The incoming audio buffer could not be recorded.")
        return
      }
      memcpy(output, input, Int(source[index].mDataByteSize))
    }
    pendingBytes += bytes
    // Queue insertion shares the admission lock with stop, so accepted audio always precedes finalization.
    queue.async { autoreleasepool {
      if !self.finished {
        do { try self.write(copy) }
        catch { self.finish(error: "Recording stopped: \(error.localizedDescription)") }
      }
      self.lock.lock()
      self.pendingBytes -= bytes
      self.lock.unlock()
    } }
  }

  // Stop admitting buffers synchronously, then drain accepted audio before closing the WAV header.
  public func stop() {
    lock.lock()
    if accepting { stopLocked(error: nil) }
    lock.unlock()
  }

  private func stopLocked(error: String?) {
    accepting = false
    queue.async { autoreleasepool { self.finish(error: error) } }
  }

  private func prepare() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let staging = directory.appendingPathComponent(".recording-\(UUID().uuidString).wav")
    let descriptor = staging.withUnsafeFileSystemRepresentation { path in
      path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o600) } ?? -1
    }
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    Darwin.close(descriptor)
    stagingURL = staging
    file = try AVAudioFile(forWriting: staging, settings: format.settings,
      commonFormat: .pcmFormatInt16, interleaved: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
  }

  private func write(_ input: AVAudioPCMBuffer) throws {
    if converter?.inputFormat != input.format {
      try drainConverter()
      converter = AVAudioConverter(from: input.format, to: format)
      converter?.primeMethod = .none
    }
    guard let converter else { throw RecordingError("The incoming audio format is unsupported.") }
    let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 512)
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      throw RecordingError("Could not allocate a recording buffer.")
    }
    var supplied = false
    while true {
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return input
      }
      if let error { throw error }
      if status == .error { throw RecordingError("Could not convert incoming audio.") }
      try append(output)
      if status != .haveData { break }
    }
  }

  private func drainConverter() throws {
    guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return }
    while true {
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, status in
        status.pointee = .endOfStream
        return nil
      }
      if let error { throw error }
      if status == .error { throw RecordingError("Could not finish converting audio.") }
      try append(output)
      if status != .haveData { break }
    }
    self.converter = nil
  }

  private func append(_ buffer: AVAudioPCMBuffer) throws {
    guard buffer.frameLength > 0 else { return }
    // Standard RIFF/WAV uses 32-bit lengths. Stop visibly before a length could wrap.
    guard framesWritten + UInt64(buffer.frameLength) <= (UInt64(UInt32.max) - 1024) / 4 else {
      throw RecordingError("The WAV size limit was reached. Audio captured so far was saved.")
    }
    guard let file else { throw RecordingError("The recording file is unavailable.") }
    try file.write(from: buffer)
    framesWritten += UInt64(buffer.frameLength)
  }

  private func finish(error: String?) {
    guard !finished else { return }
    finished = true
    lock.lock()
    accepting = false
    lock.unlock()
    var problem = error
    if problem == nil {
      do { try drainConverter() }
      catch { problem = "Could not finish recording: \(error.localizedDescription)" }
    }
    converter = nil
    let prepared = file != nil
    if #available(macOS 15, *) { file?.close() }
    file = nil // macOS 14 finalizes AVAudioFile's header when its last reference is released.
    var saved: URL?
    if let stagingURL {
      if prepared {
        do { saved = try publish(stagingURL) }
        catch {
          saved = stagingURL // Keep the recoverable recording if renaming fails.
          problem = "Audio was kept at \(stagingURL.path), but could not be renamed: \(error.localizedDescription)"
        }
      } else { try? FileManager.default.removeItem(at: stagingURL) }
    }
    completion(AudioRecordingResult(url: saved, errorMessage: problem))
  }

  private func publish(_ staging: URL) throws -> URL {
    let stem = String(filename.dropLast(4))
    for index in 1...10000 {
      let candidate = directory.appendingPathComponent(index == 1 ? filename : "\(stem)-\(index).wav")
      do {
        // moveItem refuses to replace an existing recording, including a concurrent writer's file.
        try FileManager.default.moveItem(at: staging, to: candidate)
        return candidate
      } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
    }
    throw CocoaError(.fileWriteFileExists)
  }
}

private struct RecordingError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
