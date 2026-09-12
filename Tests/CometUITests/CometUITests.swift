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

    // The native selection toggle must survive leaving the window and follow Escape and repeated clicks.
    let selection = window.descendants(matching: .any).matching(identifier: "ocr-toolbar")
      .firstMatch
    let display = window.descendants(matching: .any).matching(identifier: "remote-display")
      .firstMatch
    XCTAssertEqual(selection.value as? String, "Off")
    selection.click()
    XCTAssertEqual(selection.value as? String, "On")
    let outside = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
      .withOffset(CGVector(dx: 0, dy: 20))
    outside.hover()
    display.hover()
    XCTAssertEqual(selection.value as? String, "On", "Pointer exit must not untoggle selection")
    let armed = XCTAttachment(screenshot: window.screenshot())
    armed.name = "Text selection remains highlighted after pointer re-entry"
    armed.lifetime = .keepAlways
    add(armed)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertEqual(selection.value as? String, "Off")
    selection.click()
    XCTAssertEqual(selection.value as? String, "On")
    selection.click()
    XCTAssertEqual(selection.value as? String, "Off")

    // A drag after re-entry must reach local Vision and reset the toggle when its result is presented.
    selection.click()
    outside.hover()
    let start = display.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2))
    let end = display.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8))
    start.hover()
    start.click(forDuration: 0.2, thenDragTo: end)
    let result = window.sheets.staticTexts["Recognized Text"]
    XCTAssertTrue(
      result.waitForExistence(timeout: 15), "Re-entering must leave OCR ready to select")
    XCTAssertEqual(selection.value as? String, "Off")
    window.sheets.buttons.matching(identifier: "Done").firstMatch.click()
  }

  // Drive the shipped chat against live Comet video and a deterministic read-only Codex protocol fixture.
  @MainActor func testAgentChatPauseResumeWithLiveScreen() throws {
    guard let path = ProcessInfo.processInfo.environment["COMET_UI_SESSION_FILE"] else {
      throw XCTSkip(
        "Enable the hardware UI suite to verify agent screen observation and native controls.")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let app = XCUIApplication()
    app.launchEnvironment["COMET_MOCK_CODEX_READ_ONLY"] = "1"
    app.launchEnvironment["COMET_MOCK_CODEX_REVIEW_TEST"] = "1"
    app.launchArguments = [
      "--ui-testing", "-ApplePersistenceIgnoreState", "YES", "--session-file", path,
      "-agentCodexPath", root.appendingPathComponent("scripts/mock-codex.py").path,
    ]
    app.launch()
    defer { app.terminate() }
    app.typeKey("n", modifierFlags: .command)
    let remote = app.windows["Comet Test Session"]
    XCTAssertTrue(remote.waitForExistence(timeout: 15))
    let trust = remote.sheets.buttons.matching(identifier: "Trust This Device").firstMatch
    if trust.waitForExistence(timeout: 10) { trust.click() }
    // A newly built macOS app can lose its initial request while local-network authorization settles.
    let reconnect = remote.buttons.matching(identifier: "session-connect").firstMatch
    if reconnect.exists && reconnect.isEnabled { reconnect.click() }
    let connected = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        (remote.staticTexts["connection-status"].value as? String) == "Connected"
      }, object: remote)
    guard XCTWaiter.wait(for: [connected], timeout: 25) == .completed else {
      XCTFail("Agent UI setup could not connect to Comet: " + remote.debugDescription)
      return
    }
    remote.buttons.matching(identifier: "agent-toolbar").firstMatch.click()
    let chat = app.windows["Agent — Comet Test Session"]
    XCTAssertTrue(chat.waitForExistence(timeout: 8))
    let pause = chat.buttons.matching(identifier: "agent-pause").firstMatch
    XCTAssertTrue(pause.exists)
    XCTAssertFalse(pause.isEnabled)
    chat.checkBoxes.matching(identifier: "agent-consent").firstMatch.click()
    let composer = chat.textViews.matching(identifier: "agent-composer").firstMatch
    composer.click()
    composer.typeText("Read only: inspect this screen without clicking or typing.")
    chat.buttons.matching(identifier: "agent-send").firstMatch.click()
    let running = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in pause.isEnabled }, object: chat)
    XCTAssertEqual(XCTWaiter.wait(for: [running], timeout: 15), .completed)
    pause.click()
    let paused = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        (chat.staticTexts["agent-status"].value as? String) == "Paused" && pause.isEnabled
      }, object: chat)
    XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 10), .completed)
    XCTAssertTrue(remote.buttons.matching(identifier: "agent-session-pause").firstMatch.exists)
    pause.click()
    let completed = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        chat.staticTexts.matching(
          NSPredicate(format: "value CONTAINS %@", "Remote screen inspected.")
        ).count > 0
      }, object: chat)
    XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 30), .completed)
    XCTAssertEqual(chat.staticTexts["agent-status"].value as? String, "Ready")
    // A harmless wait tests the native approval gate without clicking or typing on the remote machine.
    composer.click()
    composer.typeText("Approval fixture: propose one harmless wait.")
    chat.buttons.matching(identifier: "agent-send").firstMatch.click()
    let approve = chat.buttons.matching(identifier: "agent-approve-action").firstMatch
    XCTAssertTrue(approve.waitForExistence(timeout: 15))
    XCTAssertTrue(chat.buttons.matching(identifier: "agent-reject-action").firstMatch.exists)
    approve.click()
    let approved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        !approve.exists && (chat.staticTexts["agent-status"].value as? String) == "Ready"
      }, object: chat)
    XCTAssertEqual(XCTWaiter.wait(for: [approved], timeout: 15), .completed)

    let attachment = XCTAttachment(screenshot: chat.screenshot())
    attachment.name = "Agent chat after screen observation and pause-resume"
    attachment.lifetime = .keepAlways
    add(attachment)
    chat.buttons.matching(identifier: "agent-stop").firstMatch.click()
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
      session.descendants(matching: .any).matching(identifier: "ocr-toolbar").firstMatch
        .waitForExistence(timeout: 5))
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
