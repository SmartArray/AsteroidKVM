import CoreVideo
// Keep high-frequency decoded frames out of SwiftUI and retain only the newest frame.
import Foundation
import WebRTC

public struct VideoMetrics: Sendable {
  public init() {}
  public var received = 0, presented = 0, replaced = 0, copied = 0
  public var width = 0, height = 0
  public var decoder = "Awaiting decoder"
  public var texturePath = "Awaiting frame"
  public var bitrate = 0.0, rttMilliseconds = 0.0
  public var renderMilliseconds = 0.0
  public var started = Date()
  public var sampled = Date()
  public var receivedFPS: Double {
    Double(received) / max(sampled.timeIntervalSince(started), 0.001)
  }
  public var presentedFPS: Double {
    Double(presented) / max(sampled.timeIntervalSince(started), 0.001)
  }
}

// The frame owns its pixel buffer through presentation and any one-time OCR snapshot.
public final class VideoFrame: @unchecked Sendable {
  // Decoder timestamps may repeat; arrival identity remains unique for presentation and agent freshness.
  public let id = UUID()
  public let buffer: CVPixelBuffer
  public let rotation: Int
  public let timestamp: Int64
  public let copied: Bool
  public let pixelAspect: CGFloat
  public init(buffer: CVPixelBuffer, rotation: Int, timestamp: Int64, copied: Bool) {
    self.buffer = buffer
    self.rotation = rotation
    self.timestamp = timestamp
    self.copied = copied
    let attachment =
      CVBufferCopyAttachment(buffer, kCVImageBufferPixelAspectRatioKey, nil) as? [String: NSNumber]
    let h =
      attachment?[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String]?.doubleValue ?? 1
    let v =
      attachment?[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String]?.doubleValue ?? 1
    pixelAspect = h / max(v, 0.001)
  }
  public var size: CGSize {
    CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
  }
}

public final class FrameMailbox: NSObject, RTCVideoRenderer, @unchecked Sendable {
  private let lock = NSLock()
  private var latest: VideoFrame?
  private var latestReceivedAt = Date.distantPast
  private var consumedID: UUID?
  private var metrics = VideoMetrics()
  private var forceCopy = false
  private let copyQueue = DispatchQueue(
    label: "app.asteroidkvm.texture-fallback", qos: .userInteractive)
  public override init() { super.init() }

  // Read dimensions from each retained pixel buffer; this advisory callback must not mutate UI state.
  public func setSize(_ size: CGSize) {}

  // The native path shares decoder CVPixelBuffers; unsupported or adapted frames use a named I420 copy fallback.
  public func renderFrame(_ frame: RTCVideoFrame?) {
    guard let frame else { return }
    let video: VideoFrame
    lock.lock()
    let copyRequired = forceCopy
    lock.unlock()
    if !copyRequired, let native = frame.buffer as? RTCCVPixelBuffer, !native.requiresCropping(),
      [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA,
      ].contains(CVPixelBufferGetPixelFormatType(native.pixelBuffer))
    {
      video = VideoFrame(
        buffer: native.pixelBuffer, rotation: frame.rotation.rawValue, timestamp: frame.timeStampNs,
        copied: false)
    } else {
      guard let buffer = copyI420(frame.buffer.toI420()) else { return }
      video = VideoFrame(
        buffer: buffer, rotation: frame.rotation.rawValue, timestamp: frame.timeStampNs,
        copied: true)
    }
    lock.lock()
    defer { lock.unlock() }
    if let latest, latest.id != consumedID { metrics.replaced += 1 }
    latestReceivedAt = Date()
    latest = video
    if metrics.received == 0 { metrics.started = Date() }
    metrics.received += 1
    metrics.width = Int(video.size.width)
    metrics.height = Int(video.size.height)
    if video.copied { metrics.copied += 1 }
    metrics.texturePath =
      video.copied ? "I420 → NV12 CPU copy → Metal" : "CVPixelBuffer → CVMetalTextureCache"
  }

  // Automation needs wall-clock freshness because decoder timestamps alone cannot reveal a stopped stream.
  public var frameAge: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return Date().timeIntervalSince(latestReceivedAt)
  }

  // Copy planar decoder output into an IOSurface-backed NV12 buffer only when sharing is unavailable.
  private func copyI420(_ source: RTCI420BufferProtocol) -> CVPixelBuffer? {
    var result: CVPixelBuffer?
    let attributes =
      [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
      as CFDictionary
    guard
      CVPixelBufferCreate(
        kCFAllocatorDefault, Int(source.width), Int(source.height),
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &result) == kCVReturnSuccess,
      let buffer = result
    else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
      let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
    else { return nil }
    for row in 0..<Int(source.height) {
      memcpy(
        y.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)),
        source.dataY.advanced(by: row * Int(source.strideY)), Int(source.width))
    }
    for row in 0..<Int(source.chromaHeight) {
      let destination = uv.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        .assumingMemoryBound(to: UInt8.self)
      for column in 0..<Int(source.chromaWidth) {
        destination[column * 2] = source.dataU[row * Int(source.strideU) + column]
        destination[column * 2 + 1] = source.dataV[row * Int(source.strideV) + column]
      }
    }
    return buffer
  }

  // Switch incompatible native buffers to a bounded off-main copy path and retry the current frame once.
  public func enableTextureFallback(for frame: VideoFrame) {
    lock.lock()
    guard !forceCopy else {
      lock.unlock()
      return
    }
    forceCopy = true
    lock.unlock()
    copyQueue.async { [weak self] in
      guard let self,
        let buffer = self.copyI420(RTCCVPixelBuffer(pixelBuffer: frame.buffer).toI420())
      else { return }
      let copy = VideoFrame(
        buffer: buffer, rotation: frame.rotation, timestamp: frame.timestamp, copied: true)
      self.lock.lock()
      defer { self.lock.unlock() }
      self.metrics.copied += 1
      self.metrics.texturePath = "I420 → NV12 CPU copy → Metal"
      if self.latest?.timestamp == frame.timestamp {
        self.latest = copy
        self.consumedID = nil
      }
    }
  }

  // Readers take a retained snapshot while the producer can immediately replace the mailbox slot.
  public func snapshot() -> VideoFrame? {
    lock.lock()
    defer { lock.unlock() }
    return latest
  }

  // Consume each received frame once while retaining the latest frame for redraw and OCR.
  public func next() -> VideoFrame? {
    lock.lock()
    defer { lock.unlock() }
    guard let latest, latest.id != consumedID else { return nil }
    consumedID = latest.id
    return latest
  }

  // Record completion only after the GPU finishes, keeping presentation counts separate from reception.
  public func presented(milliseconds: Double) {
    lock.lock()
    defer { lock.unlock() }
    metrics.presented += 1
    metrics.renderMilliseconds = milliseconds
  }

  // Copy counters under the mailbox lock for low-frequency diagnostics.
  public func statistics() -> VideoMetrics {
    lock.lock()
    defer { lock.unlock() }
    // Freeze the denominator with the counters so later inspection cannot change a recorded FPS sample.
    var snapshot = metrics
    snapshot.sampled = Date()
    return snapshot
  }

  // Merge transport measurements independently of frame delivery.
  public func updateNetwork(bitrate: Double, rtt: Double, decoder: String?) {
    lock.lock()
    defer { lock.unlock() }
    metrics.bitrate = bitrate
    metrics.rttMilliseconds = rtt
    if let decoder { metrics.decoder = decoder }
  }

  // Record the actual decoder selected by the native factory rather than infer it from a codec offer.
  public func setDecoder(_ name: String) {
    lock.lock()
    defer { lock.unlock() }
    metrics.decoder = name
  }

  // Drop retained frames and counters when a session ends so old video cannot appear after reconnect.
  public func clear() {
    lock.lock()
    defer { lock.unlock() }
    latest = nil
    consumedID = nil
  }
}

// Observe the actual decoder selected by WebRTC instead of assuming hardware decoding from the codec name.
public final class ReportingDecoderFactory: NSObject, RTCVideoDecoderFactory {
  private let factory = RTCDefaultVideoDecoderFactory()
  private let mailbox: FrameMailbox
  public init(mailbox: FrameMailbox) {
    self.mailbox = mailbox
    super.init()
  }

  // Expose the pinned native factory’s actual codec list for negotiation.
  public func supportedCodecs() -> [RTCVideoCodecInfo] { factory.supportedCodecs() }

  // Observe decoder selection while preserving the native factory’s implementation.
  public func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
    let decoder = factory.createDecoder(info)
    mailbox.setDecoder("\(info.name) · \(decoder?.implementationName() ?? "Unavailable")")
    return decoder
  }
}
