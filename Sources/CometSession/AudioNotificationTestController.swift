import AppKit
import Combine
import CometCore

// Manual tests use the normal delivery/authentication path without changing the audio cooldown or pause state.
@MainActor public final class AudioNotificationTestController: ObservableObject {
  @Published public private(set) var sending = false
  @Published public private(set) var result: String?
  @Published public private(set) var failed = false
  private var delivery: Task<Void, Never>?
  private var generation = UUID()
  private let send: (URL, AudioWebhookPayload) async throws -> Void

  public init(send: @escaping (URL, AudioWebhookPayload) async throws -> Void = {
    try await AudioWebhookClient().send(to: $0, payload: $1)
  }) {
    self.send = send
  }

  public func sendTest(profile: ConnectionProfile) {
    guard !sending else { return }
    guard let url = profile.audioNotifications?.endpointURL else {
      failed = true
      result = "Enter a valid webhook URL before testing."
      return
    }
    sending = true
    result = nil
    failed = false
    let ticket = generation
    delivery = Task { [weak self, send] in
      do {
        try Task.checkCancellation()
        let payload = AudioWebhookPayload(profile: profile, level: 0,
          screenshot: try Self.testImage(), isTest: true)
        try await send(url, payload)
        guard let self, generation == ticket, !Task.isCancelled else { return }
        result = "Test notification accepted by the receiver."
      } catch {
        guard let self, generation == ticket, !Task.isCancelled else { return }
        failed = true
        result = (error as? AudioNotificationError)?.description ?? "Could not prepare or send the test notification."
      }
      guard let self, generation == ticket else { return }
      sending = false
      delivery = nil
    }
  }

  // Editing the destination or closing Settings invalidates results from an older request.
  public func reset() {
    generation = UUID()
    delivery?.cancel()
    delivery = nil
    sending = false
    result = nil
    failed = false
  }

  private static func testImage() throws -> AudioWebhookPayload.Screenshot {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 360,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw AudioNotificationError("Could not create the test image.") }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.15, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 640, height: 360).fill()
    ("AsteroidKVM" as NSString).draw(at: NSPoint(x: 36, y: 232), withAttributes: [
      .font: NSFont.boldSystemFont(ofSize: 36), .foregroundColor: NSColor.systemCyan
    ])
    ("Audio notification test" as NSString).draw(at: NSPoint(x: 36, y: 174), withAttributes: [
      .font: NSFont.systemFont(ofSize: 27), .foregroundColor: NSColor.white
    ])
    ("Sample image • No audio detection required" as NSString).draw(at: NSPoint(x: 36, y: 112), withAttributes: [
      .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.lightGray
    ])
    guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
      throw AudioNotificationError("Could not encode the test image.")
    }
    return .init(jpeg: jpeg, width: 640, height: 360)
  }
}
