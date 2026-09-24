// Exercise observable input behavior at the protocol boundary, including mode and focus transitions.
import XCTest

@testable import CometCore
import CometSession

final class InputTests: XCTestCase {
  func testPhysicalRepeatIsOwnedByTargetAndReleaseIsBalanced() {
    var input = InputEngine()
    XCTAssertEqual(
      input.keyDown(code: "KeyA", characters: "a", modifiers: []).events, [.key("KeyA", true)])
    XCTAssertTrue(
      input.keyDown(code: "KeyA", characters: "a", modifiers: [], isRepeat: true).events.isEmpty)
    XCTAssertEqual(input.releaseAll(), [.key("KeyA", false)])
    XCTAssertTrue(input.keyUp(code: "KeyA").isEmpty)
  }

  // German symbols must be transmitted as macOS-resolved scalars rather than a client-side map.
  func testNativeGermanCharactersAndRepeat() {
    var input = InputEngine()
    input.nativeLayout = true
    input.mappedTextSupported = true
    input.keymap = "de"
    for text in ["ä", "ö", "ü", "ß", "@", "€", "[", "]", "{", "}", "\\", "|"] {
      let result = input.keyDown(code: "KeyL", characters: text, modifiers: .option)
      XCTAssertEqual(result.events.count, 1)
      XCTAssertEqual(result.events.first?.type, "mapped_text")
      XCTAssertEqual(result.events.first?.payload["text"].string, text)
      XCTAssertEqual(result.events.first?.payload["keymap"].string, "de")
      XCTAssertTrue(input.keyUp(code: "KeyL").isEmpty)
      XCTAssertEqual(
        input.keyDown(code: "KeyL", characters: text, modifiers: .option, isRepeat: true).events
          .count, 1)
    }
  }

  // Right-side modifiers remain physical identities; they must not collapse to left Alt or Control.
  func testRightOptionAndControlRemainDistinct() {
    var input = InputEngine()
    input.modifierSides = ["AltRight", "ControlRight"]
    XCTAssertEqual(
      input.keyDown(code: "KeyQ", characters: "@", modifiers: [.option, .control]).events,
      [.key("AltRight", true), .key("ControlRight", true), .key("KeyQ", true)])
    XCTAssertEqual(
      input.modifiersChanged([]), [.key("AltRight", false), .key("ControlRight", false)])
  }

  func testCapabilityIsRequiredAndFirmwareNameDoesNotEnableIt() {
    var input = InputEngine()
    input.nativeLayout = true
    XCTAssertEqual(
      input.keyDown(code: "KeyL", characters: "@", modifiers: .option).events,
      [.key("AltLeft", true), .key("KeyL", true)])
    var state = DeviceState()
    state.keymaps = .object(["firmware": .string("Kratos")])
    XCTAssertFalse(state.mappedText)
  }

  func testCommandPasteDoesNotLeakCommandOrV() {
    var input = InputEngine()
    XCTAssertTrue(input.modifiersChanged(.command).isEmpty)
    let result = input.keyDown(code: "KeyV", characters: "v", modifiers: .command)
    XCTAssertTrue(result.paste)
    XCTAssertTrue(result.events.isEmpty)
    XCTAssertTrue(input.keyUp(code: "KeyV").isEmpty)
    XCTAssertTrue(input.modifiersChanged([]).isEmpty)
    XCTAssertFalse(
      input.keyDown(code: "KeyV", characters: "v", modifiers: .command, isRepeat: true).paste)
  }

  func testShortcutToMappedTextReleasesModifiersFirst() {
    var input = InputEngine()
    input.nativeLayout = true
    input.mappedTextSupported = true
    XCTAssertEqual(
      input.keyDown(code: "KeyC", characters: "c", modifiers: .control).events,
      [.key("ControlLeft", true), .key("KeyC", true)])
    XCTAssertEqual(input.keyUp(code: "KeyC"), [.key("KeyC", false)])
    let result = input.keyDown(code: "KeyL", characters: "@", modifiers: .option)
    XCTAssertEqual(result.events.first, .key("ControlLeft", false))
    XCTAssertEqual(result.events.last?.type, "mapped_text")
  }

  func testComposedScalarsNormalizeAndUnfinishedKeysRemainLocal() {
    var input = InputEngine()
    input.nativeLayout = true
    input.mappedTextSupported = true
    let result = input.keyDown(code: "KeyA", characters: "a\u{0308}", modifiers: [])
    XCTAssertEqual(result.events.count, 1)
    XCTAssertTrue(result.events.allSatisfy { $0.payload["text"].string?.unicodeScalars.count == 1 })
    XCTAssertTrue(
      input.keyDown(code: "KeyE", characters: "", modifiers: .option).events.isEmpty)
  }

  // Composed text is normalized and does not leak Option, Shift, or a matching physical release.
  func testCommittedNativeCompositionAndRouting() {
    var input = InputEngine()
    input.nativeLayout = true
    input.mappedTextSupported = true
    input.keymap = "de"
    XCTAssertTrue(input.usesNativeText(code: "KeyN", modifiers: .option))
    XCTAssertFalse(input.usesNativeText(code: "KeyN", modifiers: .command))
    XCTAssertFalse(input.usesNativeText(code: "ArrowLeft", modifiers: []))
    XCTAssertTrue(input.beginNativeKey(code: "KeyN").isEmpty)
    XCTAssertTrue(input.keyUp(code: "KeyN").isEmpty)
    let committed = input.commitText("~n\u{0303}a\u{0308}\n")
    XCTAssertEqual(committed.map { $0.payload["text"].text }, ["~", "ñ", "ä"])
    XCTAssertTrue(committed.allSatisfy { $0.payload["keymap"].text == "de" })
    input.mappedTextSupported = false
    XCTAssertTrue(input.commitText("~").isEmpty)
  }

  func testNativeTypingIntervalPersistenceAndLegacyDefault() throws {
    var profile = ConnectionProfile(name: "Typing", host: "fixture.invalid")
    let legacy = try JSONEncoder().encode(profile)
    XCTAssertEqual(
      try JSONDecoder().decode(ConnectionProfile.self, from: legacy).nativeTypingIntervalMilliseconds,
      120)
    profile.nativeTypingIntervalMilliseconds = 0
    let saved = try JSONEncoder().encode(profile)
    XCTAssertEqual(
      try JSONDecoder().decode(ConnectionProfile.self, from: saved).nativeTypingIntervalMilliseconds,
      0)
    profile.nativeTypingIntervalMilliseconds = -10
    XCTAssertEqual(profile.nativeTypingIntervalMilliseconds, 0)
    profile.nativeTypingIntervalMilliseconds = 2000
    XCTAssertEqual(profile.nativeTypingIntervalMilliseconds, 1000)
  }

  @MainActor func testTypingIntervalUpdatesActiveOutput() {
    let session = SessionController(profile: ConnectionProfile(name: "Typing", host: "fixture.invalid"))
    let output = HIDOutput(send: { _ in }, paste: { _, _ in })
    session.output = output
    session.updateProfile { $0.nativeTypingIntervalMilliseconds = 30 }
    XCTAssertEqual(output.nativeTypingIntervalMilliseconds, 30)
    output.stop()
  }

  // Awaited transport work must not let subsequent HID events overtake a paste barrier.
  @MainActor func testOrderedQueuePasteAndIsolation() async {
    let first = EventRecorder()
    let second = EventRecorder()
    let a = HIDOutput(
      send: { await first.add($0.type + ":" + $0.payload["key"].text) },
      paste: { _, _ in
        await first.add("paste-start")
        try await Task.sleep(for: .milliseconds(40))
        await first.add("paste-end")
      })
    let b = HIDOutput(send: { await second.add($0.type) }, paste: { _, _ in })
    a.enqueue([.key("KeyA", true)])
    await a.flush()
    a.paste("hello", keymap: "en-us")
    a.enqueue([.key("KeyB", true)])
    b.enqueue([.key("KeyZ", true)])
    await b.flush()
    await a.flush()
    let values = await first.values
    XCTAssertEqual(values, ["key:KeyA", "key:KeyA", "paste-start", "paste-end"])
    let other = await second.values
    XCTAssertEqual(other, ["key"])
    XCTAssertFalse(a.pasting)
  }
}

// Keep transport test observations isolated without depending on task scheduling order.
actor EventRecorder {
  var values: [String] = []
  func add(_ value: String) { values.append(value) }
}
