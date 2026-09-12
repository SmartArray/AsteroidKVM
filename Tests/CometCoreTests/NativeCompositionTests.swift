// Exercise real AppKit dead-key interpretation through the remote surface and its serialized HID output.
import AppKit
import Carbon
import CometCore
import CometSession
import XCTest

@MainActor final class NativeCompositionTests: XCTestCase {
  // This desktop test temporarily selects German input and restores the user's source after verification.
  func testGermanDeadKeysThroughAppKitAndHID() async throws {
    guard ProcessInfo.processInfo.environment["COMET_TEXT_INPUT_E2E"] == "1" else {
      throw XCTSkip("Set COMET_TEXT_INPUT_E2E=1 on an unlocked Mac to verify AppKit composition.")
    }
    let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let sources =
      TISCreateInputSourceList(
        [kTISPropertyInputSourceID: "com.apple.keylayout.German"] as CFDictionary, true
      ).takeRetainedValue() as! [TISInputSource]
    let german = try XCTUnwrap(sources.first)
    XCTAssertEqual(TISSelectInputSource(german), noErr)
    defer { TISSelectInputSource(original) }

    // The command-line runner has no foreground app; supply key-window status while exercising the real input context.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    let session = SessionController(
      profile: ConnectionProfile(name: "Composition Test", host: "fixture.invalid"))
    session.input.nativeLayout = true
    session.input.mappedTextSupported = true
    session.input.keymap = "de"
    let recorder = CompositionRecorder()
    session.output = HIDOutput(
      send: { await recorder.add($0) },
      paste: { _, _ in XCTFail("Composition must not use the clipboard") })
    let surface = RemoteSurface(session: session)
    let window = CompositionWindow(
      contentRect: NSRect(x: 100, y: 100, width: 640, height: 400),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = surface
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    window.makeFirstResponder(surface)
    try await Task.sleep(for: .milliseconds(300))
    window.becomeKey()
    window.makeFirstResponder(surface)
    session.captured = true
    defer {
      surface.teardown()
      window.close()
    }
    XCTAssertTrue(window.isKeyWindow)
    XCTAssertTrue(window.firstResponder === surface)
    XCTAssertNotNil(surface.inputContext)
    surface.inputContext?.activate()
    surface.inputContext?.selectedKeyboardInputSource = "com.apple.keylayout.German"

    // CGEvent-backed key events let the system resolve the selected layout and its pending dead-key state.
    func press(_ key: CGKeyCode, flags: CGEventFlags = []) throws {
      let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true))
      down.flags = flags
      // Synthetic CGEvents lack the characters supplied by WindowServer for ordinary printable keys.
      if flags.isEmpty, !surface.hasMarkedText(),
        let text = [CGKeyCode(45): "n", CGKeyCode(49): " "][key]
      {
        let utf16 = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
      }
      surface.keyDown(with: try XCTUnwrap(NSEvent(cgEvent: down)))
      let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false))
      up.flags = flags
      surface.keyUp(with: try XCTUnwrap(NSEvent(cgEvent: up)))
    }
    try press(45, flags: .maskAlternate)
    XCTAssertTrue(surface.hasMarkedText(), "Option+N must remain local until committed")
    await session.output?.flush()
    let pending = await recorder.events
    XCTAssertTrue(pending.isEmpty)
    try press(49)
    XCTAssertFalse(surface.hasMarkedText())
    try press(45, flags: .maskAlternate)
    try press(45)
    await session.output?.flush()
    var sent = await recorder.events
    XCTAssertEqual(sent.map { $0.payload["text"].text }, ["~", "ñ"])

    // Escape and capture loss discard pending accents; the following key must be an ordinary n.
    try press(45, flags: .maskAlternate)
    try press(53)
    XCTAssertFalse(surface.hasMarkedText())
    try press(45)
    await session.output?.flush()
    try press(45, flags: .maskAlternate)
    session.releaseCapture()
    XCTAssertFalse(surface.hasMarkedText())
    session.captured = true
    try press(45)
    await session.output?.flush()
    sent = await recorder.events
    XCTAssertEqual(sent.map { $0.payload["text"].text }, ["~", "ñ", "n", "n"])

    // Native composition must leave physical shortcuts balanced and preserve plain navigation keys.
    try press(8, flags: .maskControl)
    try press(123)
    await session.output?.flush()
    sent = await recorder.events
    XCTAssertEqual(
      Array(sent.suffix(6)),
      [
        .key("ControlLeft", true), .key("KeyC", true), .key("KeyC", false),
        .key("ControlLeft", false), .key("ArrowLeft", true), .key("ArrowLeft", false),
      ])
  }
}

// Capture complete wire values without depending on the output worker's scheduling.
private actor CompositionRecorder {
  var events: [HIDEvent] = []
  func add(_ event: HIDEvent) { events.append(event) }
}

// Supply the focus gate in a command-line XCTest process; all AppKit text interpretation remains real.
@MainActor private final class CompositionWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}
