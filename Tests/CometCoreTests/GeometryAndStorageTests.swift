import CometCore
// Verify geometry against known source coordinates and ensure persisted profiles contain no secret fields.
import XCTest

final class GeometryAndStorageTests: XCTestCase {
  func testFitLetterboxAndOCRClamp() {
    let geometry = DisplayGeometry(
      source: CGSize(width: 1920, height: 1080), viewport: CGSize(width: 1000, height: 1000))
    XCTAssertEqual(geometry.imageRect.height, 562.5)
    XCTAssertEqual(geometry.imageRect.minY, 218.75)
    XCTAssertFalse(geometry.visibleRect.contains(CGPoint(x: 20, y: 20)))
    XCTAssertEqual(
      geometry.sourceCrop(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 2000, y: 2000)),
      CGRect(x: 0, y: 0, width: 1920, height: 1080))
  }

  func testFillCroppingRotationAndRetinaUseSameSourceCoordinates() {
    let geometry = DisplayGeometry(
      source: CGSize(width: 1920, height: 1080), viewport: CGSize(width: 800, height: 800),
      mode: .fill, rotation: 90, backingScale: 2)
    let point = geometry.sourcePoint(CGPoint(x: 400, y: 400))
    XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
    XCTAssertEqual(point.y, 0.5, accuracy: 0.0001)
    let corner = geometry.sourcePoint(.zero)
    XCTAssertGreaterThan(corner.x, 0)
    XCTAssertEqual(corner.y, 1)
    let retina = DisplayGeometry(
      source: CGSize(width: 1920, height: 1080), viewport: CGSize(width: 960, height: 540),
      mode: .actual, backingScale: 2)
    XCTAssertEqual(retina.imageRect.size, CGSize(width: 960, height: 540))
    XCTAssertEqual(retina.hidPoint(CGPoint(x: 960, y: 540)).0, 32767)
  }

  func testProfileRoundTripCannotPersistPasswordOrToken() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ProfileStore(url: directory.appendingPathComponent("profiles.json"))
    var profile = ConnectionProfile(name: "Office", host: "comet.local")
    profile.rememberPassword = false
    try store.save([profile])
    XCTAssertEqual(try store.load(), [profile])
    let data = try Data(contentsOf: store.url)
    let object = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    XCTAssertNil(object.first?["password"])
    XCTAssertNil(object.first?["token"])
    XCTAssertNotEqual(
      profile.credentialAccount,
      ConnectionProfile(name: "Office", host: "other.local").credentialAccount)
  }

  func testInvalidHostsAndPortsCannotInjectCredentialsOrPaths() {
    for host in ["", "comet.local/api", "admin@comet.local", "comet.local?x=1"] {
      XCTAssertNil(ConnectionProfile(name: "Invalid", host: host).baseURL)
    }
    XCTAssertNil(ConnectionProfile(name: "Invalid", host: "localhost", port: 0).baseURL)
    XCTAssertEqual(
      ConnectionProfile(name: "Valid", host: "localhost", port: 8443).baseURL?.port, 8443)
  }

  func testKeychainScopesAndExplicitRemoval() throws {
    let passwords = PasswordStore(service: "app.cometkvm.tests." + UUID().uuidString)
    let profile = ConnectionProfile(name: "Test", host: "keychain.invalid")
    defer { try? passwords.remove(for: profile) }
    try passwords.save("ephemeral-test-password", for: profile)
    XCTAssertEqual(try passwords.password(for: profile), "ephemeral-test-password")
    XCTAssertNil(
      try passwords.password(for: ConnectionProfile(name: "Other", host: "other.invalid")))
    try passwords.remove(for: profile)
    XCTAssertNil(try passwords.password(for: profile))
  }
}
