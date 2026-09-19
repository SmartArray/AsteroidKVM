// Validate complete EDID bytes and session workflows without touching a real display.
import CometCore
import CometSession
import XCTest

final class EDIDTests: XCTestCase {
  // Golden identity bytes catch endianness errors; every bundled mode retains HDMI audio and valid checksums.
  func testPresetsAndIdentityEncoding() throws {
    for preset in EDIDPreset.allCases {
      let document = try preset.document()
      XCTAssertEqual(document.bytes.count, 256)
      XCTAssertEqual(
        Array(document.bytes[8..<18]), [0x10, 0xac, 0x34, 0xa0, 0x4c, 0x30, 0x31, 0x30, 12, 30])
      XCTAssertEqual(document.identity, .example)
      XCTAssertEqual(document.bytes[131] & 0x40, 0x40)
      XCTAssertEqual(Array(document.bytes[132..<136]), [0x23, 9, 7, 7])
      XCTAssertEqual(document.bytes[71] & 0x80, 0)
      XCTAssertEqual(document.bytes[35] & 0x20, 0x20)
      XCTAssertGreaterThanOrEqual(Int(document.bytes[147]) * 500, preset.timing[0])
      XCTAssertEqual(try EDIDDocument(hex: document.hex), document)
      XCTAssertTrue(document.preferredMode.contains("60 Hz"))
      XCTAssertTrue(document.preferredMode.contains(String(preset.timing[1])))
    }
    XCTAssertEqual(EDIDPreset.supported(model: "GL-RM1"), EDIDPreset.allCases)
    XCTAssertTrue(EDIDPreset.supported(model: "unidentified").isEmpty)
  }

  // Editing only the identity must not change audio, timing descriptors, or unrecognized extension bytes.
  func testIdentityEditsPreserveCapabilities() throws {
    let original = try EDIDPreset.laptop.document()
    let identity = EDIDIdentity(
      manufacturer: "ACR", product: .max, serial: .max, week: 0, year: 2245)
    let edited = try original.replacingIdentity(identity)
    XCTAssertEqual(edited.identity, identity)
    XCTAssertEqual(edited.bytes[18..<127], original.bytes[18..<127])
    XCTAssertEqual(edited.bytes[128..<256], original.bytes[128..<256])
    XCTAssertThrowsError(
      try original.replacingIdentity(
        EDIDIdentity(manufacturer: "de", product: 0, serial: 0, week: 12, year: 2020)))
    XCTAssertThrowsError(
      try original.replacingIdentity(
        EDIDIdentity(manufacturer: "DEL", product: 0, serial: 0, week: 55, year: 2020)))
    XCTAssertThrowsError(
      try original.replacingIdentity(
        EDIDIdentity(manufacturer: "DEL", product: 0, serial: 0, week: 255, year: 2020)))
  }

  // Length, header, checksum, extension count, and nonhex characters are all rejected before upload.
  func testMalformedDocumentsAndMultipart() throws {
    let original = try EDIDPreset.fullHD.document()
    for index in [0, 19, 54, 126, 200, 255] {
      var bytes = original.bytes
      bytes[index] ^= 1
      XCTAssertThrowsError(try EDIDDocument(bytes: bytes))
    }
    XCTAssertThrowsError(try EDIDDocument(hex: "00FF"))
    XCTAssertThrowsError(try EDIDDocument(hex: String(repeating: "GG", count: 128)))
    let form = CometAPI.edidForm(original)
    XCTAssertTrue(form.contentType.contains("multipart/form-data; boundary="))
    let body = String(decoding: form.body, as: UTF8.self)
    XCTAssertTrue(body.contains("name=\"edid\"\r\n\r\n" + original.hex + "\r\n"))
    XCTAssertTrue(body.hasSuffix("--AsteroidEDIDBoundary--\r\n"))
  }

  // Authentication, unsupported firmware, and network failures retain their distinct actionable messages.
  @MainActor func testReadFailuresDoNotEnableWrites() async throws {
    let service = EDIDFixture(try EDIDPreset.fullHD.document())
    let controller = DisplaySettingsController(service: { service }, endpoint: { "failed-device" })
    for error in [CometError.authentication, .unsupported("EDID unavailable"), .server(500)] {
      await service.failReads(error)
      await controller.reload()
      XCTAssertFalse(controller.loaded)
      XCTAssertFalse(controller.canApply)
      XCTAssertEqual(controller.message, error.localizedDescription)
    }
    let writes = await service.writes
    XCTAssertEqual(writes, 0)
  }

  // A complete editor cycle never writes drafts and restores byte-for-byte from the persisted baseline.
  @MainActor func testDraftApplyAndPersistentRestore() async throws {
    let original = try EDIDPreset.fullHD.document()
    let service = EDIDFixture(original)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let controller = DisplaySettingsController(
      service: { service }, endpoint: { "device-one" }, backupDirectory: folder)
    await controller.reload()
    XCTAssertTrue(controller.loaded)
    XCTAssertFalse(controller.canApply)
    controller.select(.laptop)
    XCTAssertTrue(controller.canApply)
    var writes = await service.writes
    XCTAssertEqual(writes, 0)
    await controller.apply()
    XCTAssertEqual(controller.current?.preferredMode, "1920 × 1200 · 60 Hz")
    XCTAssertEqual(controller.previous, original)
    XCTAssertFalse(controller.canApply)

    // Reopening the controller proves that the backup survives a window/app lifecycle, not merely a draft.
    let reopened = DisplaySettingsController(
      service: { service }, endpoint: { "device-one" }, backupDirectory: folder)
    await reopened.reload()
    XCTAssertEqual(reopened.previous, original)
    await reopened.restore()
    XCTAssertEqual(reopened.current, original)
    writes = await service.writes
    XCTAssertEqual(writes, 2)
  }

  // A persisted known-good backup must remain usable when current EDID decoding fails after reopening Settings.
  @MainActor func testRestoreDoesNotRequireReadableCurrentEDID() async throws {
    let original = try EDIDPreset.fullHD.document()
    let service = EDIDFixture(original)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let controller = DisplaySettingsController(
      service: { service }, endpoint: { "recovery" }, backupDirectory: folder)
    await controller.reload()
    controller.select(.laptop)
    await controller.apply()
    await service.breakReadbackUntilWrite()

    // Reload reports the read failure while recovering the on-disk backup and keeping Apply disabled.
    let reopened = DisplaySettingsController(
      service: { service }, endpoint: { "recovery" }, backupDirectory: folder)
    await reopened.reload()
    XCTAssertFalse(reopened.loaded)
    XCTAssertFalse(reopened.canApply)
    XCTAssertTrue(reopened.canRestore)
    await reopened.restore()
    XCTAssertTrue(reopened.loaded)
    XCTAssertEqual(reopened.current, original)
    let writes = await service.writes
    XCTAssertEqual(writes, 2)
  }

  // Device-side concurrent edits and invalid local input must be detected before a destructive replacement.
  @MainActor func testValidationExternalChangesAndEndpointIsolation() async throws {
    let original = try EDIDPreset.fullHD.document()
    let service = EDIDFixture(original)
    var endpoint = "one"
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let controller = DisplaySettingsController(
      service: { service }, endpoint: { endpoint }, backupDirectory: folder)
    await controller.reload()
    controller.product = "0x10000"
    XCTAssertFalse(controller.canApply)
    await controller.reload()
    controller.select(.quadHD)
    await service.replace(try EDIDPreset.laptop.document())
    await controller.apply()
    XCTAssertTrue(controller.message?.contains("changed on the Comet") == true)
    let writes = await service.writes
    XCTAssertEqual(writes, 0)
    endpoint = "two"
    XCTAssertFalse(controller.canApply)
    await controller.reload()
    XCTAssertNil(controller.previous)
    XCTAssertEqual(controller.current?.preferredMode, "1920 × 1200 · 60 Hz")
  }

  // Mismatched or failed writes preserve recovery data and require an explicit reload instead of an automatic retry.
  @MainActor func testReadbackMismatchAndMissingFactoryBaseline() async throws {
    let original = try EDIDPreset.fullHD.document()
    let service = EDIDFixture(original)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let controller = DisplaySettingsController(
      service: { service }, endpoint: { "one" }, backupDirectory: folder)
    await controller.reload()
    controller.select(.laptop)
    await service.ignoreWrites()
    await controller.apply()
    XCTAssertFalse(controller.loaded)
    XCTAssertEqual(controller.previous, original)
    XCTAssertTrue(controller.message?.contains("readback differs") == true)
    let writes = await service.writes
    XCTAssertEqual(writes, 1)

    // An empty default can be edited from a template but cannot masquerade as an exact restore point.
    await service.replace(nil)
    await controller.reload()
    XCTAssertNil(controller.current)
    controller.select(.fullHD)
    XCTAssertTrue(controller.canApply)
    await controller.apply()
    XCTAssertNil(controller.previous)
  }
}

// An actor models the appliance's independently mutable configuration and counts actual upload attempts.
private actor EDIDFixture: EDIDService {
  var document: EDIDDocument?
  var writes = 0
  var ignore = false
  var readError: CometError?
  var healOnWrite = false
  init(_ document: EDIDDocument?) { self.document = document }
  // Read failures model expired sessions and missing endpoints without conflating them with factory defaults.
  func readEDID() throws -> EDIDDocument? {
    if let readError { throw readError }
    return document
  }
  func failReads(_ error: CometError) { readError = error }
  func readDisplayModel() -> String { "rm1" }
  func writeEDID(_ document: EDIDDocument) {
    writes += 1
    if healOnWrite { readError = nil }
    if !ignore { self.document = document }
  }
  func replace(_ value: EDIDDocument?) { document = value }
  func ignoreWrites() { ignore = true }

  // Model firmware whose saved EDID cannot be read until a valid replacement is uploaded.
  func breakReadbackUntilWrite() {
    readError = .invalidResponse
    healOnWrite = true
  }
}
