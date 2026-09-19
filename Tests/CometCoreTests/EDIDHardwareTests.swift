// Verify real EDID upload, video recovery, and restoration only with an explicit hardware-write opt-in.
import CometCore
import CometSession
import XCTest

final class EDIDHardwareTests: XCTestCase {
  @MainActor func testApplyReadbackVideoRecoveryAndRestore() async throws {
    guard ProcessInfo.processInfo.environment["COMET_EDID_E2E"] == "1",
      let path = ProcessInfo.processInfo.environment["COMET_E2E_SESSION"]
    else {
      throw XCTSkip(
        "Set COMET_EDID_E2E=1 and COMET_E2E_SESSION for a reversible hardware EDID test.")
    }
    let credentials = try JSONValue.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    let raw = credentials["host"].text
    let url = try XCTUnwrap(URL(string: raw.contains("://") ? raw : "https://" + raw))
    let profile = ConnectionProfile(
      name: "EDID hardware test", host: try XCTUnwrap(url.host),
      port: url.port ?? (url.scheme == "http" ? 80 : 443), scheme: url.scheme ?? "https",
      username: credentials["username"].text)
    let session = SessionController(profile: profile, token: credentials["token"].string)
    session.connect()

    // Establish normal live video and pin only the explicitly authorized test device certificate.
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline, !session.active || session.mailbox.snapshot() == nil {
      if session.pendingCertificate != nil, credentials["insecure"].bool == true {
        session.approveCertificate()
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    guard session.active, session.mailbox.snapshot() != nil else {
      await session.disconnect()
      throw EDIDError(session.message ?? "Live video did not connect.")
    }
    let settings = session.displaySettings
    await settings.reload()
    let api = try XCTUnwrap(session.api)
    guard let baseline = settings.current else {
      await session.disconnect()
      throw EDIDError(
        settings.message ?? "Exact baseline EDID is required before this test writes anything.")
    }

    // Preserve a second recovery copy outside the process before any hardware mutation.
    let backup = FileManager.default.temporaryDirectory.appendingPathComponent(
      "asteroid-edid-baseline-\(UUID().uuidString).hex")
    try baseline.hex.write(to: backup, atomically: true, encoding: .utf8)
    print("EDID recovery backup: \(backup.path)")
    do {
      settings.select(.fullHD)
      XCTAssertTrue(settings.canApply)
      await settings.apply()
      guard settings.loaded else { throw EDIDError(settings.message ?? "EDID application failed.") }
      let expected = try XCTUnwrap(settings.current)
      let readback = try await api.readEDID()
      XCTAssertEqual(readback, expected)
      XCTAssertEqual(expected.preferredMode, "1920 × 1080 · 60 Hz")
      // Count only frames arriving after the upload/readback, excluding frames from before HDMI renegotiation.
      try await waitForVideo(session, after: session.mailbox.statistics().received)
      print(
        "EDID applied: \(expected.preferredMode); received \(session.mailbox.statistics().width)x\(session.mailbox.statistics().height)"
      )

      // Restore through the production controller and prove the original exact bytes and live video return.
      await settings.restore()
      let restored = try await api.readEDID()
      XCTAssertEqual(restored, baseline)
      guard restored == baseline else { throw EDIDError("Baseline restoration did not match.") }
      try await waitForVideo(session, after: session.mailbox.statistics().received)
      print("EDID baseline restored and live video recovered.")
      await session.disconnect()
    } catch {
      // A failed assertion path must still attempt exact restoration; leave the disk recovery copy available.
      do { try await api.writeEDID(baseline) } catch {
        XCTFail(
          "Emergency EDID restore failed: \(error.localizedDescription); backup: \(backup.path)")
      }
      await session.disconnect()
      throw error
    }
  }

  // Require newly received frames rather than accepting a stale decoder snapshot as successful recovery.
  @MainActor private func waitForVideo(_ session: SessionController, after count: Int) async throws
  {
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline {
      if session.mailbox.statistics().received > count + 15, session.mailbox.frameAge < 2,
        session.state.online != false
      {
        return
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw EDIDError("Live HDMI video did not recover within 45 seconds.")
  }
}
