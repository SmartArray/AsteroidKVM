import AVFoundation
import CometCore
import CometMedia
import CometSession
import CoreVideo
import ImageIO
import WebRTC
import XCTest

final class AudioNotificationTests: XCTestCase {
  func testLegacyProfilesAndPreferencesRoundTrip() throws {
    var profile = ConnectionProfile(name: "Desk", host: "desk.local")
    let legacy = try JSONEncoder().encode(profile)
    let restored = try JSONDecoder().decode(ConnectionProfile.self, from: legacy)
    XCTAssertNil(restored.audioOutputDeviceUID)
    XCTAssertNil(restored.audioNotifications)
    XCTAssertFalse(AudioNotificationPreferences().enabled)
    XCTAssertEqual(AudioNotificationPreferences().cooldown, 30)
    profile.audioOutputDeviceUID = "aggregate-output-uid"
    profile.audioNotifications = preferences()
    profile.audioNotifications?.alias = "Build Mac"
    XCTAssertEqual(try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile)), profile)
  }

  func testEndpointValidationAndBounds() {
    var prefs = preferences()
    for url in ["", "file:///tmp/screen", "ftp://example.com", "https://user:pass@example.com", "https://example.com/#token", "https://example.com:0"] {
      prefs.endpoint = url
      XCTAssertNil(prefs.endpointURL, url)
    }
    for url in ["http://127.0.0.1:1234/hook", "https://example.com/hook?key=secret"] {
      prefs.endpoint = url
      XCTAssertNotNil(prefs.endpointURL)
    }
    prefs.cooldownSeconds = -.infinity
    XCTAssertEqual(prefs.cooldown, 30)
    prefs.cooldownSeconds = -1
    XCTAssertEqual(prefs.cooldown, 1)
    prefs.cooldownSeconds = 1_000_000
    XCTAssertEqual(prefs.cooldown, 86400)
    prefs.thresholdDecibels = .nan
    XCTAssertEqual(prefs.threshold, -40)
  }

  func testAudioMonitorRetainsBriefSoundsAndHandlesPCMLayouts() throws {
    for format in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32] {
      for interleaved in [false, true] {
        let monitor = AudioActivityMonitor()
        XCTAssertEqual(monitor.takeLevel(), 0)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: format, sampleRate: 48000, channels: 2, interleaved: interleaved))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        pcm.frameLength = 480
        for channel in 0..<(interleaved ? 1 : 2) {
          for index in 0..<(interleaved ? 960 : 480) {
            pcm.int16ChannelData?[channel][index] = 8192
            pcm.floatChannelData?[channel][index] = 0.25
          }
        }
        monitor.render(pcmBuffer: pcm)
        // Silence arriving before the main-actor poll must not erase a short tone.
        for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
          memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
        monitor.render(pcmBuffer: pcm)
        XCTAssertEqual(monitor.takeLevel(), 0.25, accuracy: 0.0001)
        XCTAssertEqual(monitor.takeLevel(), 0)
      }
    }
  }

  func testCooldownSuppressesSilenceNoiseAndRepeatedAudio() {
    var gate = AudioNotificationGate()
    var prefs = preferences()
    XCTAssertFalse(gate.admit(level: 0, preferences: prefs, now: 0))
    XCTAssertFalse(gate.admit(level: 0.001, preferences: prefs, now: 0))
    XCTAssertFalse(gate.admit(level: .nan, preferences: prefs, now: 0))
    XCTAssertTrue(gate.admit(level: 0.1, preferences: prefs, now: 0))
    XCTAssertFalse(gate.admit(level: 1, preferences: prefs, now: 29.99))
    XCTAssertTrue(gate.admit(level: 1, preferences: prefs, now: 30))
    prefs.enabled = false
    XCTAssertFalse(gate.admit(level: 1, preferences: prefs, now: 60))
    prefs.enabled = true
    prefs.cooldownSeconds = 60
    XCTAssertFalse(gate.admit(level: 1, preferences: prefs, now: 60))
    XCTAssertTrue(gate.admit(level: 1, preferences: prefs, now: 90))
  }

  @MainActor func testDeliveryContainsIdentityAndJPEGAndHonorsCooldownAcrossReconnect() async throws {
    var sent: [AudioWebhookPayload] = []
    var now = 0.0
    let controller = AudioNotificationController(send: { _, payload in sent.append(payload) }, clock: { now })
    var profile = ConnectionProfile(name: "Office", host: "office.local")
    profile.muted = true
    profile.audioNotifications = preferences()
    profile.audioNotifications?.alias = "  Workstation  "
    controller.configure(profile: profile, connected: true)
    let mailbox = try mailbox()
    controller.receive(level: 0.2, mailbox: mailbox)
    for _ in 0..<20 { controller.receive(level: 0.2, mailbox: mailbox) }
    try await waitUntil { !controller.sending }
    XCTAssertEqual(sent.count, 1)
    let payload = try XCTUnwrap(sent.first)
    XCTAssertEqual(payload.kvm.id, profile.id)
    XCTAssertEqual(payload.kvm.name, "Office")
    XCTAssertEqual(payload.kvm.alias, "Workstation")
    XCTAssertEqual(payload.message, "Audio detected on Workstation")
    let jpeg = try XCTUnwrap(Data(base64Encoded: payload.screenshot.base64))
    let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(image.width, 1600)
    XCTAssertEqual(image.height, 900)
    let json = try JSONValue.decode(payload.data())
    XCTAssertEqual(json["event"].string, "audio_detected")
    XCTAssertNotNil(ISO8601DateFormatter().date(from: try XCTUnwrap(json["timestamp"].string)))
    XCTAssertNil(json["kvm"]["host"].string)
    XCTAssertNotNil(controller.lastDelivery)
    controller.stop()
    controller.configure(profile: profile, connected: true)
    now = 29
    controller.receive(level: 0.2, mailbox: mailbox)
    XCTAssertFalse(controller.sending)
    now = 30
    controller.receive(level: 0.2, mailbox: mailbox)
    try await waitUntil { !controller.sending }
    XCTAssertEqual(sent.count, 2)
  }

  @MainActor func testMissingScreenshotDoesNotConsumeCooldown() async throws {
    var count = 0
    let controller = AudioNotificationController(send: { _, _ in count += 1 }, clock: { 0 })
    var profile = ConnectionProfile(name: "Desk", host: "desk.local")
    profile.audioNotifications = preferences()
    controller.configure(profile: profile, connected: true)
    controller.receive(level: 0.2, mailbox: FrameMailbox())
    XCTAssertFalse(controller.sending)
    XCTAssertEqual(controller.status, "Waiting for a live screenshot")
    controller.receive(level: 0.2, mailbox: try mailbox())
    try await waitUntil { !controller.sending }
    XCTAssertEqual(count, 1)
  }

  @MainActor func testDisableStopOrPauseDuringCaptureNeverSends() async throws {
    for action in ["disable", "stop", "pause"] {
      var count = 0
      var resume: CheckedContinuation<AudioWebhookPayload.Screenshot, Error>?
      let controller = AudioNotificationController(send: { _, _ in count += 1 }, capture: { _ in
        try await withCheckedThrowingContinuation { resume = $0 }
      })
      var profile = ConnectionProfile(name: "Desk", host: "desk.local")
      profile.audioNotifications = preferences()
      controller.configure(profile: profile, connected: true)
      controller.receive(level: 0.2, mailbox: try mailbox())
      try await waitUntil { resume != nil }
      if action == "disable" {
        profile.audioNotifications?.enabled = false
        controller.configure(profile: profile, connected: true)
      } else if action == "pause" {
        controller.setPaused(true)
      } else { controller.stop() }
      resume?.resume(returning: .init(jpeg: Data([1]), width: 1, height: 1))
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertFalse(controller.sending)
      XCTAssertEqual(count, 0)
      XCTAssertNil(controller.lastDelivery)
    }
  }

  @MainActor func testStatusBarPauseSuppressesDeliveryAndPreservesCooldownAcrossReconnect() async throws {
    var count = 0
    var now = 0.0
    let controller = AudioNotificationController(send: { _, _ in count += 1 }, clock: { now })
    var profile = ConnectionProfile(name: "Desk", host: "desk.local")
    profile.audioNotifications = preferences()
    controller.configure(profile: profile, connected: true)
    let mailbox = try mailbox()
    XCTAssertTrue(controller.isArmed)
    controller.receive(level: 0.2, mailbox: mailbox)
    try await waitUntil { !controller.sending }
    XCTAssertEqual(count, 1)

    controller.setPaused(true)
    XCTAssertFalse(controller.isArmed)
    XCTAssertEqual(controller.status, "Paused from status bar")
    controller.stop()
    controller.configure(profile: profile, connected: true)
    XCTAssertTrue(controller.isPaused)
    now = 30
    controller.receive(level: 0.2, mailbox: mailbox)
    XCTAssertFalse(controller.sending)
    XCTAssertEqual(count, 1)

    // Resuming does not replay suppressed sounds; it waits for a fresh activity callback.
    controller.setPaused(false)
    XCTAssertTrue(controller.isArmed)
    XCTAssertFalse(controller.sending)
    controller.receive(level: 0.2, mailbox: mailbox)
    try await waitUntil { !controller.sending }
    XCTAssertEqual(count, 2)
    controller.setPaused(true)
    controller.setPaused(false)
    now = 59
    controller.receive(level: 0.2, mailbox: mailbox)
    XCTAssertFalse(controller.sending, "Pausing and resuming must not bypass the cooldown")

    controller.setPaused(true)
    profile.audioNotifications?.alias = "Updated alias"
    controller.configure(profile: profile, connected: true)
    XCTAssertTrue(controller.isPaused, "Editing settings must preserve the session's pause")
    profile.audioNotifications?.enabled = false
    controller.configure(profile: profile, connected: true)
    XCTAssertFalse(controller.isArmed)
    XCTAssertEqual(controller.status, "Disabled")
    profile.audioNotifications?.enabled = true
    controller.configure(profile: profile, connected: true)
    XCTAssertTrue(controller.isArmed, "Explicitly enabling notifications activates delivery")
    controller.receive(level: 0.2, mailbox: mailbox)
    XCTAssertFalse(controller.sending, "Re-enabling must also preserve the cooldown")
  }

  @MainActor func testFailureCooldownAndConnectionIsolation() async throws {
    var count = 0
    var now = 0.0
    let failed = AudioNotificationController(send: { _, _ in
      count += 1
      throw AudioNotificationError("Webhook delivery failed (HTTP 503).")
    }, clock: { now })
    let other = AudioNotificationController(send: { _, _ in count += 1 }, clock: { now })
    var profile = ConnectionProfile(name: "Desk", host: "desk.local")
    profile.audioNotifications = preferences()
    let mailbox = try mailbox()
    failed.configure(profile: profile, connected: true)
    other.configure(profile: profile, connected: true)
    failed.receive(level: 0.2, mailbox: mailbox)
    try await waitUntil { !failed.sending }
    XCTAssertNotNil(failed.lastError)
    XCTAssertNil(failed.lastDelivery)
    failed.receive(level: 0.2, mailbox: mailbox)
    XCTAssertFalse(failed.sending)
    other.receive(level: 0.2, mailbox: mailbox)
    try await waitUntil { !other.sending }
    XCTAssertEqual(count, 2)
    now = 30
    failed.receive(level: 0.2, mailbox: mailbox)
    try await waitUntil { !failed.sending }
    XCTAssertEqual(count, 3)
  }

  @MainActor func testManualNotificationResetDiscardsLateResultsAndRedactsUnexpectedErrors() async throws {
    var completions: [CheckedContinuation<Void, Error>] = []
    let controller = AudioNotificationTestController(send: { _, _ in
      try await withCheckedThrowingContinuation { completions.append($0) }
    })
    var profile = ConnectionProfile(name: "Test", host: "test.local")
    controller.sendTest(profile: profile)
    XCTAssertTrue(controller.failed)
    XCTAssertFalse(controller.sending)
    profile.audioNotifications = preferences()
    controller.sendTest(profile: profile)
    try await waitUntil { completions.count == 1 }
    controller.reset()
    XCTAssertNil(controller.result)
    XCTAssertFalse(controller.sending)
    controller.sendTest(profile: profile)
    try await waitUntil { completions.count == 2 }
    completions[0].resume()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(controller.sending, "The canceled request must not finish the newer request")
    XCTAssertNil(controller.result)
    completions[1].resume(throwing: NSError(domain: "test", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Failed https://example.com/?token=private-secret"]))
    try await waitUntil { !controller.sending }
    XCTAssertTrue(controller.failed)
    XCTAssertEqual(controller.result, "Could not prepare or send the test notification.")
  }

  private func preferences() -> AudioNotificationPreferences {
    var result = AudioNotificationPreferences()
    result.enabled = true
    result.endpoint = "https://example.com/webhook"
    return result
  }

  private func mailbox() throws -> FrameMailbox {
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let pixelBuffer = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    memset(CVPixelBufferGetBaseAddress(pixelBuffer), 128, CVPixelBufferGetDataSize(pixelBuffer))
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    let mailbox = FrameMailbox()
    mailbox.renderFrame(RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: 1))
    return mailbox
  }

  @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw AudioNotificationError("Timed out waiting for notification fixture")
  }
}
