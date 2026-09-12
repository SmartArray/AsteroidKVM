// Exercise the shipped AppKit/SwiftUI application through macOS accessibility and native windows.
import XCTest

final class CometUITests: XCTestCase {
  // The explicit hardware variant observes real video and media ownership without typing remote input.
  @MainActor func testHardwareVideoSurvivesNativeFullscreen() throws {
    guard let path = ProcessInfo.processInfo.environment["COMET_UI_SESSION_FILE"], !path.isEmpty,
      !path.hasPrefix("$(")
    else {
      throw XCTSkip(
        "Set COMET_UI_SESSION_FILE through xcodebuild to opt into hardware UI verification.")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let sessionFile = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing", "-ApplePersistenceIgnoreState", "YES", "--session-file", path,
    ]
    app.launch()
    defer { app.terminate() }
    app.typeKey("n", modifierFlags: .command)
    let window = app.windows["Comet Test Session"]
    guard window.waitForExistence(timeout: 15) else {
      XCTFail("Expected the imported session window. " + app.debugDescription)
      return
    }
    // Scope approval to the window sheet because macOS also mirrors its default action in the Touch Bar.
    let trust = window.sheets.buttons.matching(identifier: "Trust This Device").firstMatch
    if sessionFile["insecure"] as? Bool == true,
      trust.waitForExistence(timeout: 15)
    {
      trust.click()
    }

    // Diagnostics are production UI; observe counters rather than injecting a synthetic video source.
    let connected = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        window.staticTexts["connection-status"].exists
          && (window.staticTexts["connection-status"].value as? String
            ?? window.staticTexts["connection-status"].label) == "Connected"
      }, object: window)
    guard XCTWaiter.wait(for: [connected], timeout: 25) == .completed else {
      XCTFail(
        "Live session did not connect: " + window.staticTexts["connection-status"].debugDescription)
      return
    }
    func counters() -> (Int, Int) {
      window.descendants(matching: .any).matching(identifier: "actions-toolbar").firstMatch.click()
      app.menuItems["Diagnostics…"].click()
      let frames = window.sheets.staticTexts["diagnostic-received"]
      XCTAssertTrue(frames.waitForExistence(timeout: 5))
      let received = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in (Int(frames.value as? String ?? frames.label) ?? 0) > 100
        }, object: frames)
      XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 15), .completed)
      let result = (
        Int(frames.value as? String ?? frames.label) ?? 0,
        Int(
          window.sheets.staticTexts["diagnostic-media-starts"].value as? String
            ?? window.sheets.staticTexts["diagnostic-media-starts"].label) ?? 0
      )
      window.sheets.buttons.matching(identifier: "Done").firstMatch.click()
      return result
    }
    let before = counters()
    let original = window.frame
    app.typeKey("f", modifierFlags: [.control, .command])
    let entered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in window.frame.height > original.height + 10 }, object: window)
    XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 8), .completed)
    let screenshot = XCTAttachment(screenshot: window.screenshot())
    screenshot.name = "Live Comet in native fullscreen"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.typeKey("f", modifierFlags: [.control, .command])
    let exited = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in abs(window.frame.height - original.height) < 5 },
      object: window)
    XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 8), .completed)
    let after = counters()
    XCTAssertGreaterThan(after.0, before.0, "Live frames must continue across both transitions")
    XCTAssertEqual(before.1, 1)
    XCTAssertEqual(after.1, before.1, "Fullscreen must preserve the existing WebRTC connection")
  }

  @MainActor func testConnectionCreationWindowKeyboardSettingsAndFullscreen() throws {
    let app = XCUIApplication()
    // Ignore restored windows so every run starts with the isolated, empty connection store.
    app.launchArguments = ["--ui-testing", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    app.typeKey("n", modifierFlags: .command)
    XCTAssertTrue(app.buttons["add-connection"].waitForExistence(timeout: 10))
    app.buttons["add-connection"].click()
    let name = app.textFields["profile-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.click()
    name.typeText("UI Test Comet")
    let host = app.textFields["profile-host"]
    host.click()
    host.typeText("127.0.0.1")
    let port = app.textFields["profile-port"]
    port.click()
    port.typeKey("a", modifierFlags: .command)
    port.typeText("9")
    app.buttons["Save"].click()
    let connect = app.buttons["connect-UI Test Comet"]
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    connect.click()
    // Scope toolbar queries to the session because SwiftUI exposes nested accessibility buttons.
    let session = app.windows["UI Test Comet"]
    let keyboard = session.buttons.matching(identifier: "keyboard-toolbar").firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
    keyboard.click()
    let native = app.checkBoxes["native-layout-toggle"]
    XCTAssertTrue(native.waitForExistence(timeout: 5))
    XCTAssertFalse(native.isEnabled)
    app.typeKey(.escape, modifierFlags: [])

    // Check actual window geometry so dispatching the shortcut alone cannot masquerade as fullscreen.
    let originalFrame = session.frame
    app.typeKey("f", modifierFlags: [.control, .command])
    let entered = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in session.frame.height > originalFrame.height + 10 },
      object: session)
    XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 8), .completed)
    XCTAssertTrue(
      session.buttons.matching(identifier: "ocr-toolbar").firstMatch.waitForExistence(timeout: 5))
    app.typeKey("f", modifierFlags: [.control, .command])
    let exited = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in abs(session.frame.height - originalFrame.height) < 5 },
      object: session)
    XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 8), .completed)
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["Devices"].waitForExistence(timeout: 5))
    app.staticTexts["Devices"].firstMatch.click()
    XCTAssertTrue(app.staticTexts["Configure Comet"].waitForExistence(timeout: 5))
    app.staticTexts["System"].firstMatch.click()
    XCTAssertTrue(app.staticTexts["Hardware Identity"].waitForExistence(timeout: 5))
    app.terminate()
  }
}
