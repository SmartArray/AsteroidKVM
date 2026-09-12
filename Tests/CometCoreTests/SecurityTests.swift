// Regress protocol conversion, endpoint trust, and link-policy findings without hardware or model access.
import CometAgent
import CometCore
import CometSession
import XCTest

final class SecurityTests: XCTestCase {
  // Extreme but valid JSON numbers must stay printable and never trap when a protocol expects an integer.
  func testUntrustedNumericBoundaries() throws {
    let payload = try JSONValue.decode(Data("{\"error\":{\"code\":1e100}}".utf8))
    XCTAssertEqual(payload["error"]["code"].text, "1e+100")
    for number in [
      1e100, -1e100, Double(Int.max), 0.5, Double.infinity, -Double.infinity, Double.nan,
    ] {
      XCTAssertNil(JSONValue.number(number).integer())
      XCTAssertFalse(JSONValue.number(number).text.isEmpty)
    }
    XCTAssertEqual(JSONValue.number(Double(Int.min)).integer(), Int.min)
    XCTAssertEqual(JSONValue.number(42).integer(in: 0...100), 42)
    XCTAssertNil(JSONValue.number(-1).integer(in: 0...Int(Int32.max)))
    XCTAssertNil(JSONValue.number(Double(Int32.max) + 1).integer(in: 0...Int(Int32.max)))
    XCTAssertNil(JSONValue.number(1.5).integer(in: 1...Int.max))
  }

  // Device-provided limits cannot make preset checks overflow or silently accept fractional ranges.
  func testMalformedVideoBoundsDisablePreset() {
    var state = DeviceState()
    for minimum in [1e100, -1e100, 0.5] {
      state.streamer = .object([
        "params": .object(["h264_bitrate": .number(500)]),
        "limits": .object([
          "h264_bitrate": .object(["min": .number(minimum), "max": .number(1000)])
        ]),
      ])
      XCTAssertFalse(VideoPreset.firmwarePresets[0].supported(by: state))
    }
  }

  // Both persisted profiles and live replacements must drop approval when any transport endpoint component changes.
  @MainActor func testEndpointEditsClearCertificateExceptions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ProfileStore(url: directory.appendingPathComponent("profiles.json"))
    let model = AppModel(profileStoreURL: store.url)
    var original = ConnectionProfile(name: "A", host: "a.invalid")
    original.certificateSHA256 = "approved-certificate"
    for mutation: (inout ConnectionProfile) -> Void in [
      { $0.host = "b.invalid" }, { $0.port = 8443 }, { $0.scheme = "http" },
    ] {
      try model.save(original, password: nil)
      let session = model.createSession(profile: original)
      var updated = original
      mutation(&updated)
      try model.save(updated, password: nil)
      XCTAssertNil(try store.load().first?.certificateSHA256)
      await session.replaceProfile(updated, password: nil)
      XCTAssertNil(session.profile.certificateSHA256)
    }
    var cosmetic = original
    cosmetic.name = "Renamed"
    cosmetic.host = "A.INVALID"
    XCTAssertEqual(
      cosmetic.securingReplacement(of: original).certificateSHA256, original.certificateSHA256)
  }

  // Live identity invalidation also applies to idle agents and resets previously granted full-control permission.
  @MainActor func testIdentityChangesResetAgentPermissionsButDisplayChangesDoNot() async {
    let model = AppModel(
      profileStoreURL: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString))
    let session = model.createSession(profile: ConnectionProfile(name: "A", host: "a.invalid"))
    let agent = model.agent(for: session)
    for change: (inout ConnectionProfile) -> Void in [
      { $0.host = "b.invalid" }, { $0.username = "different" }, { $0.certificateSHA256 = "new" },
    ] {
      agent.setControlMode(.fullControl)
      session.updateProfile(change)
      XCTAssertEqual(agent.controlMode, .review)
      XCTAssertFalse(agent.canResume)
      XCTAssertTrue(agent.messages.isEmpty)
    }
    agent.setControlMode(.fullControl)
    session.updateProfile { $0.scaleMode = .fill }
    XCTAssertEqual(agent.controlMode, .fullControl)
  }

  // The policy rejects local handlers and credential-bearing URLs regardless of the label rendered by Markdown.
  func testChatLinkPolicy() throws {
    for text in [
      "file:///private/tmp/result", "javascript:alert(1)", "ssh://host", "vscode://file/result",
      "https://user:secret@example.com",
    ] {
      let url = try XCTUnwrap(URL(string: text))
      XCTAssertFalse(AgentLinkPolicy.allows(url), text)
    }
    for text in ["https://example.com/path?q=a", "http://example.com"] {
      XCTAssertTrue(AgentLinkPolicy.allows(try XCTUnwrap(URL(string: text))))
    }
    let parsed = try AttributedString(markdown: "[Safe result](file:///private/tmp/result)")
    let url = try XCTUnwrap(parsed.runs.compactMap(\.link).first)
    XCTAssertFalse(AgentLinkPolicy.allows(url))
  }
}
