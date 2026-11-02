import AppKit
import CometCore
@testable import CometSession
import XCTest

@MainActor final class WindowTabbingTests: XCTestCase {
  func testCapturedTabAndShiftTabReachRemoteUnlessWindowTabsAreEnabled() async throws {
    let defaults = UserDefaults.standard
    let saved = defaults.object(forKey: WindowTabbing.preferenceKey)
    let automatic = NSWindow.allowsAutomaticWindowTabbing
    defaults.removeObject(forKey: WindowTabbing.preferenceKey)
    defer {
      if let saved { defaults.set(saved, forKey: WindowTabbing.preferenceKey) }
      else { defaults.removeObject(forKey: WindowTabbing.preferenceKey) }
      NSWindow.allowsAutomaticWindowTabbing = automatic
    }
    XCTAssertFalse(WindowTabbing.enabled)
    let session = SessionController(profile: ConnectionProfile(name: "Tab test", host: "fixture.invalid"))
    let recorder = TabRecorder()
    session.output = HIDOutput(send: { await recorder.add($0) }, paste: { _, _ in })
    let window = TabTestWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let surface = RemoteSurface(session: session)
    surface.allowsAutomaticCapture = false
    window.contentView = surface
    window.makeFirstResponder(surface)
    session.captured = true
    defer { surface.teardown(); window.close() }
    XCTAssertEqual(window.tabbingMode, .disallowed)

    func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t",
        charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
    }
    for native in [false, true] {
      session.input.nativeLayout = native
      session.input.mappedTextSupported = native
      for flags: NSEvent.ModifierFlags in [[], .shift] {
        XCTAssertNil(surface.routeTabEvent(try event(.keyDown, flags: flags)))
        XCTAssertNil(surface.routeTabEvent(try event(.keyUp, flags: flags)))
        surface.flagsChanged(with: try event(.flagsChanged))
      }
    }
    await session.output?.flush()
    let expected: [HIDEvent] = [.key("Tab", true), .key("Tab", false),
      .key("ShiftLeft", true), .key("Tab", true), .key("Tab", false), .key("ShiftLeft", false)]
    let forwarded = await recorder.events
    XCTAssertEqual(forwarded, expected + expected)

    // Local editors and released surfaces must never lose their Tab events.
    session.captured = false
    XCTAssertNotNil(surface.routeTabEvent(try event(.keyDown)))
    session.captured = true
    let field = NSTextView(frame: .zero)
    surface.addSubview(field)
    window.makeFirstResponder(field)
    XCTAssertNotNil(surface.routeTabEvent(try event(.keyDown)))
    window.makeFirstResponder(surface)
    session.captured = true

    defaults.set(true, forKey: WindowTabbing.preferenceKey)
    WindowTabbing.configure(window)
    XCTAssertEqual(window.tabbingMode, .preferred)
    for flags: NSEvent.ModifierFlags in [[], .shift] {
      window.makeFirstResponder(surface)
      session.captured = true
      let down = try event(.keyDown, flags: flags)
      XCTAssertNotNil(surface.routeTabEvent(down))
      surface.keyDown(with: down)
      surface.keyUp(with: try event(.keyUp, flags: flags))
    }
    await session.output?.flush()
    let afterLocalTabs = await recorder.events
    XCTAssertEqual(afterLocalTabs, forwarded)

    defaults.set(false, forKey: WindowTabbing.preferenceKey)
    WindowTabbing.applyToOpenWindows()
    XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
    XCTAssertEqual(window.tabbingMode, .disallowed)
  }
}

@MainActor private final class TabTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}

private actor TabRecorder {
  var events: [HIDEvent] = []
  func add(_ event: HIDEvent) { events.append(event) }
}
