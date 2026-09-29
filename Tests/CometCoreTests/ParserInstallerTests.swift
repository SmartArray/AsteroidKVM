import CometCore
import CryptoKit
import Foundation
import XCTest

@testable import CometSession

final class ParserInstallerTests: XCTestCase {
  private var package: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("services/omniparser")
  }
  private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Parser Installer " + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  @MainActor func testShippedManifestAndResourcesAreComplete() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LocalParserManager(root: root, package: package)
    let release = try manager.release()
    XCTAssertEqual(release.version, "1.0.0")
    XCTAssertEqual(release.runtimeURL.scheme, "https")
    XCTAssertNil(manager.installedVersion)
  }
  func testRuntimeChecksumRejectsCorruptedDownloads() throws {
    let bytes = Data("pinned runtime".utf8)
    let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let release = LocalParserRelease(
      schemaVersion: 1, version: "1",
      runtimeURL: URL(
        string:
          "https://github.com/astral-sh/python-build-standalone/releases/download/fixture/runtime.tar.gz"
      )!, runtimeSHA256: hash, runtimeBytes: Int64(bytes.count))
    try release.validate()
    try release.verify(bytes)
    XCTAssertThrowsError(try release.verify(Data("pinned runtimf".utf8)))
    XCTAssertThrowsError(try release.verify(bytes + Data([0])))
    let unsafe = LocalParserRelease(
      schemaVersion: 1, version: "1", runtimeURL: URL(string: "http://example.com/runtime.tar.gz")!,
      runtimeSHA256: hash, runtimeBytes: 14)
    XCTAssertThrowsError(try unsafe.validate())
  }
  func testOnlyOneManagerMayInstallOrOwnService() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var first: ParserInstallLock? = try ParserInstallLock(root: root)
    XCTAssertThrowsError(try ParserInstallLock(root: root))
    withExtendedLifetime(first) {}
    first = nil
    XCTAssertNoThrow(try ParserInstallLock(root: root))
  }
  @MainActor func testInvalidInstallDoesNotReplaceWorkingVersion() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let record = LocalParserManager.Installation(
      directory: "runtime-" + UUID().uuidString, version: "previous")
    let original = try JSONEncoder().encode(record)
    try original.write(to: root.appendingPathComponent("active.json"))
    let manager = LocalParserManager(
      root: root, package: root.appendingPathComponent("missing resources"))
    do {
      try await manager.installPackage()
      XCTFail("Missing resources accepted")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("active.json")), original)
    XCTAssertEqual(manager.installedVersion, "previous")
  }
  @MainActor func testCancelledInstallPreservesActiveRecord() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let record = LocalParserManager.Installation(
      directory: "runtime-" + UUID().uuidString, version: "previous")
    let original = try JSONEncoder().encode(record)
    try original.write(to: root.appendingPathComponent("active.json"))
    let manager = LocalParserManager(root: root, package: package)
    let task = Task { try await manager.installPackage() }
    task.cancel()
    do {
      try await task.value
      XCTFail("Cancelled installer continued")
    } catch is CancellationError {}
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("active.json")), original)
    XCTAssertNoThrow(try ParserInstallLock(root: root))
  }

  @MainActor func testCleanupKeepsCurrentPreviousAndUnrelatedFiles() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let versions = root.appendingPathComponent("versions")
    let names = (0..<3).map { _ in "runtime-" + UUID().uuidString } + ["user-notes"]
    for name in names {
      try FileManager.default.createDirectory(
        at: versions.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    LocalParserManager(root: root, package: package).pruneVersions(keeping: Set(names.prefix(2)))
    XCTAssertEqual(
      Set(try FileManager.default.contentsOfDirectory(atPath: versions.path)),
      Set([names[0], names[1], "user-notes"]))
  }

  @MainActor func testInstallationRecordCannotEscapeManagedRoot() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let record = LocalParserManager.Installation(directory: "runtime-../../outside", version: "1")
    try JSONEncoder().encode(record).write(to: root.appendingPathComponent("active.json"))
    let manager = LocalParserManager(root: root, package: package)
    XCTAssertThrowsError(try manager.activeInstallation())
  }
  @MainActor func testRealStandaloneInstallStartParseAndStop() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["COMET_PARSER_INSTALL_E2E"] == "1", let path = env["COMET_PARSER_INSTALL_ROOT"] else {
      throw XCTSkip(
        "Set COMET_PARSER_INSTALL_E2E=1 and COMET_PARSER_INSTALL_ROOT to explicitly download and test a complete installation."
      )
    }
    let root = URL(fileURLWithPath: path)
    let manager = LocalParserManager(root: root, package: package)
    if env["COMET_PARSER_SKIP_INSTALL"] != "1" { try await manager.installPackage() }
    XCTAssertNotNil(manager.installedVersion)
    try await manager.verifyInstallation(directory: manager.installationDirectory)
    var settings = PerceptionSettings()
    settings.enabled = true
    settings.port = 19122
    do {
      try await manager.startService(settings: settings)
      XCTAssertTrue(manager.running)
      // Independent app instances are rejected while this helper owns the installation.
      XCTAssertThrowsError(try ParserInstallLock(root: root))
      let client = OmniParserClient(settings: settings, token: try manager.accessToken())
      let health = try await client.health()
      XCTAssertTrue(health.modelsLoaded)
      let data = try Data(
        contentsOf: package.deletingLastPathComponent().deletingLastPathComponent()
          .appendingPathComponent("Tests/Fixtures/Perception/browser.png"))
      // The service accepts either image encoding; frame IDs hash the exact uploaded bytes.
      let frame = try PerceptionFrame(
        width: 960, height: 640, timestamp: Date().timeIntervalSince1970,
        image: data, pixels: Data(repeating: 0, count: 960 * 640 * 4))
      let result = try await client.parse(frame: frame)
      XCTAssertTrue(result.detections.contains { $0.description?.isEmpty == false })
      await manager.stopService()
      XCTAssertFalse(manager.running)
      XCTAssertNoThrow(try ParserInstallLock(root: root))
      try await manager.startService(settings: settings)
      XCTAssertTrue(manager.running)
      await manager.shutdown()
      XCTAssertFalse(manager.running)
    } catch {
      await manager.shutdown()
      throw error
    }
  }
}
