import CometCore
import CometMedia
import CoreText
import MetalKit
import WebRTC
// Exercise the real decoder mailbox, Metal pipeline compilation, and Apple Vision on native pixel buffers.
import XCTest

final class MediaTests: XCTestCase {
  private func buffer(width: Int = 640, height: Int = 240) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
          as CFDictionary, &buffer), kCVReturnSuccess)
    return try XCTUnwrap(buffer)
  }

  func testMailboxIsBoundedAndNativeBuffersAreShared() throws {
    let mailbox = FrameMailbox()
    let buffer = try buffer()
    for stamp in 1...120 {
      mailbox.renderFrame(
        RTCVideoFrame(
          buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64(stamp)))
    }
    XCTAssertEqual(mailbox.statistics().received, 120)
    XCTAssertEqual(mailbox.statistics().replaced, 119)
    XCTAssertEqual(mailbox.statistics().copied, 0)
    let latest = try XCTUnwrap(mailbox.next())
    XCTAssertEqual(latest.timestamp, 120)
    XCTAssertTrue(latest.buffer === buffer)
    XCTAssertNil(mailbox.next())
    mailbox.clear()
    XCTAssertNil(mailbox.snapshot())
  }

  // Live decoder callbacks with repeated timestamps must still produce new displayed and observed frames.
  func testRepeatedDecoderTimestampsDoNotFreezeTheMailbox() throws {
    let mailbox = FrameMailbox()
    let buffer = try buffer()
    mailbox.renderFrame(
      RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 0))
    let first = try XCTUnwrap(mailbox.next())
    mailbox.renderFrame(
      RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 0))
    let second = try XCTUnwrap(mailbox.next())
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(first.timestamp, second.timestamp)
    XCTAssertLessThan(mailbox.frameAge, 1)
  }

  @MainActor func testMetalPipelineCompilesAndPresentsSharedBuffer() async throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let mailbox = FrameMailbox()
    let buffer = try buffer()
    let renderer = try MetalVideoRenderer(mailbox: mailbox, device: device)
    let view = MTKView(frame: CGRect(x: 0, y: 0, width: 640, height: 240), device: device)
    view.colorPixelFormat = .bgra8Unorm
    view.delegate = renderer
    view.isPaused = true
    mailbox.renderFrame(
      RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: 1))
    renderer.draw(in: view)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertGreaterThan(mailbox.statistics().presented, 0)
    XCTAssertEqual(mailbox.statistics().texturePath, "CVPixelBuffer → CVMetalTextureCache")
  }

  func testVisionReadsOnlyTheSelectedStableFrame() async throws {
    let buffer = try buffer()
    CVPixelBufferLockBaseAddress(buffer, [])
    let context = try XCTUnwrap(
      CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 240, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 240))
    let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: "COMET 123",
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
            gray: 0, alpha: 1),
        ]))
    context.textPosition = CGPoint(x: 40, y: 100)
    CTLineDraw(line, context)
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let frame = VideoFrame(buffer: buffer, rotation: 0, timestamp: 1, copied: false)
    let result = try await TextRecognition.recognize(
      frame: frame, crop: CGRect(x: 0, y: 0, width: 640, height: 240), languages: ["en-US"])
    XCTAssertTrue(result.contains("COMET"))
    XCTAssertTrue(result.contains("123"))
  }
}
