import CometCore
import XCTest

final class PastePreparationTests: XCTestCase {
  func testGermanDeadKeysKeepLiteralSpacesAndComposedLetters() throws {
    let source = "`error` ^ ´ ~ ¨ é ä\n` "
    XCTAssertEqual(try PastePreparation.prepare(source, keymap: "de", options: PasteOptions()),
      "` error`  ^  ´  ~ ¨ é ä\n`  ")
    XCTAssertEqual(try PastePreparation.prepare(source, keymap: "en-us", options: PasteOptions()), source)
    var options = PasteOptions()
    options.handleDeadKeys = false
    XCTAssertEqual(try PastePreparation.prepare(source, keymap: "de", options: options), source)
    XCTAssertEqual(try PastePreparation.prepare(source, keymap: "custom", options: options), source)
    XCTAssertThrowsError(try PastePreparation.prepare(source, keymap: "custom", options: PasteOptions()))
  }

  func testExpansionCannotExceedFirmwareLimit() throws {
    let source = String(repeating: "`", count: 8192)
    XCTAssertEqual(try PastePreparation.prepare(source, keymap: "de", options: PasteOptions()).count, 16384)
    XCTAssertThrowsError(try PastePreparation.prepare(source + "`", keymap: "de", options: PasteOptions())) {
      XCTAssertEqual($0 as? CometError, .pasteTooLong)
    }
    XCTAssertThrowsError(try PastePreparation.prepare(String(repeating: "x", count: 16385),
      keymap: "en-us", options: PasteOptions()))
  }

  func testOldProfilesRetainDefaultsAndChoicesRoundTrip() throws {
    var profile = ConnectionProfile(name: "Paste", host: "fixture.invalid")
    let legacy = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
    XCTAssertNil(legacy.pasteOptions)
    XCTAssertTrue((legacy.pasteOptions ?? PasteOptions()).handleDeadKeys)
    XCTAssertFalse((legacy.pasteOptions ?? PasteOptions()).fastMode)
    var options = PasteOptions()
    options.handleDeadKeys = false
    options.fastMode = true
    profile.pasteOptions = options
    profile.keymap = "de"
    let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
    XCTAssertEqual(restored, profile)
  }
}
