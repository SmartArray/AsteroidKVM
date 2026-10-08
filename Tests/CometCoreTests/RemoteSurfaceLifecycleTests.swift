// Guard SwiftUI dismantling against synchronous ObservableObject publication and verify eventual cleanup.
import AppKit
import Combine
import CometCore
@testable import CometSession
import XCTest

@MainActor final class RemoteSurfaceLifecycleTests: XCTestCase {
  func testHitTestingUsesParentCoordinatesAcrossToolbarInsets() {
    let session = SessionController(
      profile: ConnectionProfile(name: "Hit test", host: "fixture.invalid"))
    let surface = RemoteSurface(session: session)
    defer { surface.teardown() }
    for parent in [NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)),
                   FlippedHitTestParent(frame: NSRect(x: 0, y: 0, width: 800, height: 600))] {
      let root = NSView(frame: parent.frame)
      root.addSubview(parent)
      parent.addSubview(surface)
      // Toolbar and status-bar layout can offset the surface within its parent.
      for origin in [NSPoint.zero, NSPoint(x: 24, y: 48)] {
        surface.frame = NSRect(origin: origin, size: NSSize(width: 640, height: 400))
        for local in [NSPoint(x: 1, y: 1), NSPoint(x: 639, y: 1),
                      NSPoint(x: 1, y: 399), NSPoint(x: 639, y: 399)] {
          let point = surface.convert(local, to: parent)
          XCTAssertTrue(surface.hitTest(point) === surface,
                        "Visible edge must accept hits: local=\(local), origin=\(origin), flipped=\(parent.isFlipped)")
          XCTAssertTrue(parent.hitTest(parent.convert(point, to: root)) === surface)
        }
        for local in [NSPoint(x: -1, y: 200), NSPoint(x: 641, y: 200),
                      NSPoint(x: 320, y: -1), NSPoint(x: 320, y: 401)] {
          XCTAssertNil(surface.hitTest(surface.convert(local, to: parent)),
                       "Outside points must not steal toolbar/status-bar clicks")
        }
      }
      surface.removeFromSuperview()
    }
  }

  func testHitTestingRespectsHiddenSurfaceAndRoutesPassiveChildren() {
    let session = SessionController(
      profile: ConnectionProfile(name: "Hit test", host: "fixture.invalid"))
    let surface = RemoteSurface(session: session)
    defer { surface.teardown() }
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    surface.frame = NSRect(x: 24, y: 48, width: 640, height: 400)
    parent.addSubview(surface)
    surface.addSubview(NSView(frame: surface.bounds))
    let point = surface.convert(NSPoint(x: 100, y: 100), to: parent)
    XCTAssertTrue(surface.hitTest(point) === surface, "Passive rendering children must not receive input")
    surface.isHidden = true
    XCTAssertNil(surface.hitTest(point))
    surface.isHidden = false
    surface.teardown()
    XCTAssertNil(surface.hitTest(point))
  }

  // Observe real session publications while dismantling the surface, including repeated AppKit cleanup.
  func testTeardownDefersSessionPublicationAndReleasesCapture() async throws {
    let session = SessionController(
      profile: ConnectionProfile(name: "Lifecycle Test", host: "fixture.invalid"))
    let surface = RemoteSurface(session: session)
    session.captured = true
    session.ocrSelecting = true
    session.ocrBusy = true
    var publications = 0
    let observation = session.objectWillChange.sink { publications += 1 }
    defer { observation.cancel() }

    // The representable destruction callback must not reenter SwiftUI's graph through any published property.
    surface.teardown()
    surface.teardown()
    XCTAssertTrue(surface.resignFirstResponder())
    XCTAssertEqual(publications, 0)
    XCTAssertFalse(surface.allowsAutomaticCapture)

    // A main-actor turn must still release capture and cancel OCR after the synchronous callback returns.
    for _ in 0..<100 where session.captured || session.ocrSelecting || session.ocrBusy {
      await Task.yield()
    }
    XCTAssertFalse(session.captured)
    XCTAssertFalse(session.ocrSelecting)
    XCTAssertFalse(session.ocrBusy)
    XCTAssertGreaterThan(publications, 0)
  }
  func testLockedSurfaceRejectsEventsAndRetainsEmergencyStop() async throws {
    var profile = ConnectionProfile(name: "Locked surface", host: "fixture.invalid")
    var preferences = MCPPreferences()
    preferences.enabled = true
    preferences.allowControl = true
    preferences.port = Int.random(in: 20000...60000)
    profile.mcp = preferences
    let session = SessionController(profile: profile)
    let server = DeviceMCPServer(session: session, testToken: "surface-fixture")
    session.mcpServer = server
    session.phase = .connected
    server.configure()
    defer { server.disable() }
    for _ in 0..<100 where server.status == "Starting…" {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(server.status, "Listening")
    let recorder = EventRecorder()
    session.output = HIDOutput(send: { await recorder.add($0.type) }, paste: { _, _ in
      await recorder.add("paste")
    })
    let surface = RemoteSurface(session: session)
    let window = LockedSurfaceWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = surface
    window.makeFirstResponder(surface)
    defer { surface.teardown(); window.close() }
    session.setMCPInputLocked(true)
    XCTAssertTrue(session.mcpInputLocked)
    var interruptions = 0
    session.onAgentInterruption = { interruptions += 1 }
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertFalse(session.captured)
    XCTAssertEqual(interruptions, 0)

    // Even stale capture state must not allow events past the lock.
    session.captured = true
    func key(_ type: NSEvent.EventType, code: UInt16 = 0,
             flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: code))
    }
    let down = try key(.keyDown)
    surface.keyDown(with: down)
    surface.keyUp(with: try key(.keyUp))
    surface.flagsChanged(with: try key(.flagsChanged, code: 56, flags: .shift))
    surface.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
    surface.setMarkedText("a", selectedRange: NSRange(location: 0, length: 1),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
    let mouse = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
      location: NSPoint(x: 30, y: 30), modifierFlags: [], timestamp: 1,
      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    surface.mouseDown(with: mouse)
    surface.mouseUp(with: mouse)
    surface.rightMouseDown(with: mouse)
    surface.rightMouseUp(with: mouse)
    surface.otherMouseDown(with: mouse)
    surface.otherMouseUp(with: mouse)
    surface.mouseMoved(with: mouse)
    surface.mouseDragged(with: mouse)
    let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
      wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
    surface.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: scroll)))
    await session.output?.flush()
    let blocked = await recorder.values
    XCTAssertTrue(blocked.isEmpty)
    XCTAssertFalse(surface.hasMarkedText())
    XCTAssertEqual(interruptions, 0)
    surface.keyDown(with: try key(.keyDown, code: 53, flags: [.control, .option, .command]))
    XCTAssertEqual(interruptions, 1, "Emergency stop must bypass the manual input lock")
    XCTAssertTrue(session.mcpInputLocked)

    session.setMCPInputLocked(false)
    session.captured = true
    surface.keyDown(with: down)
    surface.keyUp(with: try key(.keyUp))
    await session.output?.flush()
    let unlocked = await recorder.values
    XCTAssertEqual(unlocked, ["key", "key"], "The same focused surface accepts input after unlocking")
  }

}

@MainActor private final class LockedSurfaceWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}

@MainActor private final class FlippedHitTestParent: NSView {
  override var isFlipped: Bool { true }
}
