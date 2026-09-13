// Exercise the shipped AppKit/SwiftUI application through macOS accessibility and native windows.
import AppKit
import Carbon
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
    // Open the local manager through its menu because a focused display now captures ordinary Command shortcuts.
    app.menuBars.menuBarItems["File"].click()
    app.menuItems["Connections…"].click()
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

    let reconnect = window.buttons["session-connect"].firstMatch
    if reconnect.exists && reconnect.isEnabled { reconnect.click() }

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
    let selection = window.checkBoxes.matching(identifier: "ocr-toolbar")
      .firstMatch
    let display = window.descendants(matching: .any).matching(identifier: "remote-display")
      .firstMatch
    // Native checkboxes can expose NSNumber values; do not mistake a selected checkbox for a missing String.
    func selectionIsOn() -> Bool {
      if let number = selection.value as? NSNumber { return number.boolValue }
      return ["1", "On"].contains(selection.value as? String ?? "")
    }
    XCTAssertFalse(selectionIsOn())
    selection.click()
    XCTAssertTrue(selectionIsOn())
    let outside = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
      .withOffset(CGVector(dx: 0, dy: 20))
    outside.hover()
    display.hover()
    XCTAssertTrue(
      selectionIsOn(),
      "Pointer exit must not untoggle selection")
    let armed = XCTAttachment(screenshot: window.screenshot())
    armed.name = "Text selection remains highlighted after pointer re-entry"
    armed.lifetime = .keepAlways
    add(armed)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(selectionIsOn())
    selection.click()
    XCTAssertTrue(selectionIsOn())
    selection.click()
    XCTAssertFalse(selectionIsOn())

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
    XCTAssertFalse(selectionIsOn())
    // Preserve every clipboard representation while checking that Cancel leaves it untouched.
    let clipboard = NSPasteboard.general
    let originalItems: [NSPasteboardItem] =
      clipboard.pasteboardItems?.map { item in
        let copy = NSPasteboardItem()
        for type in item.types {
          if let data = item.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
      } ?? []
    defer {
      clipboard.clearContents()
      clipboard.writeObjects(originalItems)
    }
    let sentinel = "Asteroid OCR clipboard fixture"
    clipboard.clearContents()
    clipboard.setString(sentinel, forType: .string)
    window.sheets.buttons["ocr-cancel"].firstMatch.click()
    XCTAssertTrue(result.waitForNonExistence(timeout: 5))
    XCTAssertTrue(
      clipboard.string(forType: .string) == sentinel, "Cancel must not change the clipboard")

    // A second real recognition verifies that Copy & Close copies the displayed result and dismisses the sheet.
    selection.click()
    start.click(forDuration: 0.2, thenDragTo: end)
    XCTAssertTrue(result.waitForExistence(timeout: 15))
    let text = window.sheets.staticTexts["ocr-result-text"].firstMatch
    let expected = text.value as? String ?? text.label
    let copy = window.sheets.buttons["ocr-copy-close"].firstMatch
    XCTAssertEqual(copy.label, "Copy & Close")
    XCTAssertTrue(copy.isEnabled, "The live test region must contain readable text")
    copy.click()
    XCTAssertTrue(result.waitForNonExistence(timeout: 5))
    XCTAssertTrue(
      clipboard.string(forType: .string) == expected, "Copy must contain the recognized text")
  }

  // Verify real WindowServer dead keys on live video without committing text to the remote machine.
  @MainActor func testNativeDeadKeyPreviewAndCancellationWithLiveVideo() throws {
    guard let path = ProcessInfo.processInfo.environment["COMET_UI_SESSION_FILE"] else {
      throw XCTSkip(
        "Enable hardware UI verification to test native dead keys on the remote display.")
    }
    let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let sources =
      TISCreateInputSourceList(
        [kTISPropertyInputSourceID: "com.apple.keylayout.German"] as CFDictionary, true
      ).takeRetainedValue() as! [TISInputSource]
    let german = try XCTUnwrap(sources.first)
    defer { TISSelectInputSource(original) }
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing", "-ApplePersistenceIgnoreState", "YES", "--session-file", path,
    ]
    app.launch()
    defer { app.terminate() }
    // Open the local manager through its menu because a focused display now captures ordinary Command shortcuts.
    app.menuBars.menuBarItems["File"].click()
    app.menuItems["Connections…"].click()
    let remote = app.windows["Comet Test Session"]
    XCTAssertTrue(remote.waitForExistence(timeout: 15))
    let trust = remote.sheets.buttons["Trust This Device"]
    if trust.waitForExistence(timeout: 5) { trust.click() }
    let reconnect = remote.buttons["session-connect"].firstMatch
    if reconnect.exists && reconnect.isEnabled { reconnect.click() }
    let connected = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        let status = remote.staticTexts["connection-status"]
        return status.exists && (status.value as? String ?? status.label) == "Connected"
      }, object: remote)
    guard XCTWaiter.wait(for: [connected], timeout: 25) == .completed else {
      XCTFail("The live display must connect before keyboard verification")
      return
    }

    // Connection completion focuses the display without a capture click; explicit release remains effective.
    let captureStatus = remote.staticTexts["capture-status"]
    func isCaptured() -> Bool {
      (captureStatus.value as? String ?? captureStatus.label).hasPrefix("Remote input")
    }
    let captured = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in isCaptured() }, object: remote)
    XCTAssertEqual(XCTWaiter.wait(for: [captured], timeout: 5), .completed)
    app.typeKey(.escape, modifierFlags: [.control, .option, .command])
    let staysReleased = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in isCaptured() }, object: remote)
    staysReleased.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [staysReleased], timeout: 1), .completed)

    // Enable only the native typing preference; the pending dead key never leaves this Mac.
    remote.buttons["keyboard-toolbar"].firstMatch.click()
    let native = app.checkBoxes["native-layout-toggle"].firstMatch
    XCTAssertTrue(native.waitForExistence(timeout: 5))
    guard native.isEnabled else {
      XCTFail("The test Comet must support mapped_text")
      return
    }
    if native.value as? String != "1" { native.click() }
    XCTAssertFalse(isCaptured(), "The keyboard popover must not grant remote input")
    app.typeKey(.escape, modifierFlags: [])
    app.menuBars.menuBarItems["File"].click()
    app.menuItems["Connections…"].click()
    XCTAssertFalse(isCaptured(), "Switching away must release remote input")
    remote.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
      .withOffset(CGVector(dx: 0, dy: 12)).click()
    let refocused = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in isCaptured() }, object: remote)
    XCTAssertEqual(XCTWaiter.wait(for: [refocused], timeout: 5), .completed)
    // Returning from another app must also recapture the same display window without a screen click.
    XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
    XCTAssertFalse(isCaptured(), "Leaving the app must release remote input")
    app.activate()
    let reactivated = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in isCaptured() }, object: remote)
    XCTAssertEqual(XCTWaiter.wait(for: [reactivated], timeout: 5), .completed)
    // The very first typed key after activation reaches AppKit composition without clicking the display.
    XCTAssertEqual(TISSelectInputSource(german), noErr)
    app.typeKey("n", modifierFlags: .option)
    let preview = remote.staticTexts["native-composition"].firstMatch
    XCTAssertTrue(preview.waitForExistence(timeout: 5))
    let attachment = XCTAttachment(screenshot: remote.screenshot())
    attachment.name = "Local tilde composition on live Comet video"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(preview.exists, "Escape must discard the unfinished accent")

    // Opening another native control releases capture and must clear pending composition immediately.
    app.typeKey("n", modifierFlags: .option)
    XCTAssertTrue(preview.waitForExistence(timeout: 5))
    remote.buttons["keyboard-toolbar"].firstMatch.click()
    XCTAssertFalse(preview.exists, "Losing display focus must discard the unfinished accent")
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
    app.launchEnvironment["COMET_MOCK_CODEX_EXPECT_MODEL"] = "gpt-5.6-luna"
    app.launchEnvironment["COMET_MOCK_CODEX_EXPECT_EFFORT"] = "high"
    app.launchArguments = [
      "--ui-testing", "-ApplePersistenceIgnoreState", "YES", "--session-file", path,
      "-agentCodexPath", root.appendingPathComponent("scripts/mock-codex.py").path,
    ]
    app.launch()
    defer { app.terminate() }
    // Open the local manager through its menu because a focused display now captures ordinary Command shortcuts.
    app.menuBars.menuBarItems["File"].click()
    app.menuItems["Connections…"].click()
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
    // Options start collapsed; the summary remains below the prompt and opens a native popover on demand.
    let options = chat.buttons["agent-options"].firstMatch
    let summary = chat.staticTexts["agent-options-summary"].firstMatch
    XCTAssertTrue(summary.exists)
    XCTAssertFalse(chat.popUpButtons["agent-model-selector"].exists)
    XCTAssertGreaterThanOrEqual(summary.frame.minY, chat.textViews["agent-composer"].frame.maxY)
    options.click()
    // Wait for runtime discovery, then verify the visible Luna selection is used by the subprocess fixture.
    let model = app.popUpButtons.matching(identifier: "agent-model-selector").firstMatch
    XCTAssertTrue(model.waitForExistence(timeout: 5))
    let modelsLoaded = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in model.isEnabled }, object: model)
    XCTAssertEqual(XCTWaiter.wait(for: [modelsLoaded], timeout: 10), .completed)
    let previousModel = model.value as? String ?? "Codex default"
    let thinking = app.popUpButtons["agent-thinking-selector"].firstMatch
    let previousThinking = thinking.value as? String ?? "Automatic (Medium)"
    model.click()
    let luna = app.menuItems["GPT-5.6-Luna"]
    XCTAssertTrue(luna.waitForExistence(timeout: 10))
    luna.click()
    // Confirm the visible effort choice reaches the real subprocess protocol, not just saved UI state.
    XCTAssertTrue(thinking.isEnabled)
    thinking.click()
    app.menuItems["High"].click()
    let optionsScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    optionsScreenshot.name = "Agent options popover"
    optionsScreenshot.lifetime = .keepAlways
    add(optionsScreenshot)
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(model.exists)
    XCTAssertTrue(
      (summary.value as? String ?? summary.label).contains("GPT-5.6-Luna · High thinking"))
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

    // Exercise the reported short-window layout with a real pending click, without approving remote input.
    let corner = chat.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -3, dy: -3))
    corner.click(
      forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 0, dy: 580 - chat.frame.height)))
    composer.click()
    composer.typeText("Click preview fixture: propose a click for review only.")
    chat.buttons.matching(identifier: "agent-send").firstMatch.click()
    XCTAssertTrue(approve.waitForExistence(timeout: 15))
    let description = chat.staticTexts.matching(identifier: "agent-approval-description").firstMatch
    XCTAssertTrue(description.exists)
    XCTAssertGreaterThanOrEqual(description.frame.height, 16)
    XCTAssertTrue(
      chat.frame.contains(description.frame), "The complete action must fit in a short chat window")
    XCTAssertTrue(approve.isHittable)
    let marker = remote.images.matching(identifier: "agent-click-preview").firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 5))

    // Reopening the options popover changes the pending marker and updates its compact summary immediately.
    options.click()
    let previewToggle = app.checkBoxes["agent-click-preview-toggle"].firstMatch
    previewToggle.click()
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(marker.waitForNonExistence(timeout: 5))
    XCTAssertTrue((summary.value as? String ?? summary.label).contains("Preview off"))
    options.click()
    previewToggle.click()
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(marker.waitForExistence(timeout: 5))
    XCTAssertTrue((summary.value as? String ?? summary.label).contains("Preview on"))
    let preview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    preview.name = "Readable click approval with purple remote-display preview"
    preview.lifetime = .keepAlways
    add(preview)
    chat.buttons.matching(identifier: "agent-reject-action").firstMatch.click()
    XCTAssertTrue(marker.waitForNonExistence(timeout: 5))

    let attachment = XCTAttachment(screenshot: chat.screenshot())
    attachment.name = "Agent chat after screen observation and pause-resume"
    attachment.lifetime = .keepAlways
    add(attachment)
    chat.buttons.matching(identifier: "agent-stop").firstMatch.click()
    // Restore the preceding preference so UI verification does not change the user's chosen model.
    options.click()
    model.click()
    app.menuItems[previousModel].click()
    thinking.click()
    app.menuItems[previousThinking].click()
  }

  @MainActor func testConnectionCreationWindowKeyboardSettingsAndFullscreen() throws {
    let app = XCUIApplication()
    // Ignore restored windows so every run starts with the isolated, empty connection store.
    app.launchArguments = ["--ui-testing", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    // Open the local manager through its menu because a focused display now captures ordinary Command shortcuts.
    app.menuBars.menuBarItems["File"].click()
    app.menuItems["Connections…"].click()
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
