import AppKit
import CometCore
import CometMedia
import CoreVideo
import WebRTC
@testable import CometSession
import XCTest

@MainActor final class ReviewRegressionTests: XCTestCase {
  func testDelayedTextureFallbackDoesNotOverwriteReplacementConnectionFrame() async throws {
    let mailbox = FrameMailbox()
    // Hold the existing conversion queue to reproduce completion after reconnect deterministically.
    let copyQueue = try XCTUnwrap(Mirror(reflecting: mailbox).children.first(where: {
      $0.label == "copyQueue"
    })?.value as? DispatchQueue)
    let gate = DispatchSemaphore(value: 0)
    copyQueue.async { gate.wait() }
    defer { gate.signal() }
    func frame(_ value: UInt8) throws -> RTCVideoFrame {
      var buffer: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
      let pixelBuffer = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(value), CVPixelBufferGetDataSize(pixelBuffer))
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      return RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: 1)
    }
    mailbox.renderFrame(try frame(32))
    mailbox.enableTextureFallback(for: try XCTUnwrap(mailbox.snapshot()))
    mailbox.clear() // Disconnect/reconnect replaces the stream, but reuses its mailbox.
    mailbox.renderFrame(try frame(200)) // Decoder timestamps can repeat after reconnect.
    let newFrame = try XCTUnwrap(mailbox.snapshot())
    gate.signal()
    await withCheckedContinuation { continuation in copyQueue.async { continuation.resume() } }
    XCTAssertEqual(mailbox.snapshot()?.id, newFrame.id, "Old conversion must not replace the new connection's frame")
  }

  func testWindowCloseStillDisconnectsWhenSurfaceIsDismantledImmediately() async throws {
    let session = SessionController(profile: ConnectionProfile(name: "Review", host: "fixture.invalid"))
    session.phase = .connected
    weak var removedSurface: RemoteSurface?
    autoreleasepool {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      var surface: RemoteSurface? = RemoteSurface(session: session)
      removedSurface = surface
      window.contentView = surface
      NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
      surface?.teardown()
      window.contentView = nil
      surface = nil
    }
    XCTAssertNil(removedSurface, "The probe must release the disappearing viewer")
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(session.phase, .disconnected, "Closing a viewer must disconnect even if its view is destroyed first")
    await session.disconnect()
  }

  func testResolutionSelectionPreservesExistingMonitorName() async throws {
    let document = try EDIDPreset.fullHD.document(
      identity: EDIDIdentity(manufacturer: "AUS", product: 0x24B2, serial: 1, week: 1, year: 2020),
      displayName: "ASUS Display")
    let service = ReviewEDIDService(document)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settings = DisplaySettingsController(service: { service }, endpoint: { "review-fixture" },
      backupDirectory: directory)
    await settings.reload()
    settings.select(.quadHD)
    let proposal = try settings.proposal()
    XCTAssertEqual(proposal.identity.manufacturer, "AUS")
    XCTAssertEqual(proposal.displayName, "ASUS Display", "Changing resolution should preserve the monitor name")
  }
}

private actor ReviewEDIDService: EDIDService {
  var document: EDIDDocument
  init(_ document: EDIDDocument) { self.document = document }
  func readEDID() -> EDIDDocument? { document }
  func readDisplayModel() -> String { "rm1" }
  func writeEDID(_ document: EDIDDocument) { self.document = document }
}
