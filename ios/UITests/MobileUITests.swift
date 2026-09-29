import XCTest

final class MobileUITests: XCTestCase {
  @MainActor func testSaveEditAndDeleteWithoutRememberingPassword() {
    let app = XCUIApplication()
    app.launchArguments = ["-onboardingVersion", "1"]
    app.launch()
    let profileName = "No Keychain \(UUID().uuidString.prefix(8))"
    app.buttons["Add connection"].firstMatch.tap()
    let name = app.textFields["connection-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText(profileName)
    app.textFields["connection-host"].tap()
    app.textFields["connection-host"].typeText("fixture.invalid")
    let remember = app.switches["Remember password in Keychain"]
    XCTAssertEqual(remember.value as? String, "0")
    app.buttons["Save"].tap()
    XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))

    // Verify disk persistence and editing an endpoint that never had a saved secret.
    app.terminate()
    app.launch()
    let row = app.staticTexts[profileName]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.press(forDuration: 1)
    app.buttons["Edit connection"].tap()
    let host = app.textFields["connection-host"]
    XCTAssertTrue(host.waitForExistence(timeout: 5))
    host.tap()
    host.typeText(".updated")
    XCTAssertEqual(remember.value as? String, "0")
    app.buttons["Save"].tap()
    XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["fixture.invalid.updated"].exists)
    row.swipeLeft()
    app.buttons["Delete"].tap()
    XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    app.terminate()
    app.launch()
    XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
    XCTAssertFalse(row.exists)
  }

  @MainActor func testGuideAndConnectionEditor() {
    let app = XCUIApplication()
    app.launchArguments = ["-onboardingVersion", "0"]
    app.launch()
    app.buttons["Add connection"].firstMatch.tap()
    let name = app.textFields["connection-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText("UI fixture")
    app.textFields["connection-host"].tap()
    app.textFields["connection-host"].typeText("fixture.invalid")
    XCTAssertTrue(app.buttons["Save"].isEnabled)
    app.buttons["Cancel"].tap()
    app.buttons["More"].tap()
    app.buttons["Gesture Guide"].tap()
    XCTAssertTrue(app.staticTexts["Point and click"].waitForExistence(timeout: 5))
    screenshot("onboarding-pointer", app)
    app.buttons["Next"].tap()
    XCTAssertTrue(app.staticTexts["Pan and zoom"].exists)
    app.buttons["Next"].tap()
    XCTAssertTrue(app.staticTexts["Scroll remotely"].exists)
    screenshot("onboarding-scroll", app)
    app.buttons["Next"].tap()
    XCTAssertTrue(app.staticTexts["Your controls, within reach"].exists)
    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
  }
  @MainActor func testSessionMenuTypingSettingsAndRotation() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    app.launchArguments = ["-onboardingVersion", "1"]
    app.launch()
    let controls = app.buttons["connection-controls"]
    XCTAssertTrue(controls.waitForExistence(timeout: 10))
    screenshot("remote-portrait", app)
    controls.tap()
    XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
    screenshot("connection-menu", app)
    app.buttons["Type"].tap()
    let editor = app.textViews.firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.tap()
    editor.typeText("echo 'hello'\nsecond line")
    app.buttons["Send"].tap()
    XCTAssertTrue(controls.waitForExistence(timeout: 5))
    XCTAssertFalse(app.navigationBars["Type"].exists)
    XCTAssertTrue(app.staticTexts["Text sent"].waitForExistence(timeout: 6))
    controls.tap()
    app.buttons["Special keys"].tap()
    XCTAssertTrue(app.buttons["Escape"].waitForExistence(timeout: 5))
    app.buttons["Escape"].tap()
    XCTAssertTrue(controls.waitForExistence(timeout: 5))
    controls.tap()
    app.buttons["Shortcuts"].tap()
    XCTAssertTrue(app.buttons["Ctrl+Alt+Del"].waitForExistence(timeout: 5))
    app.buttons["Ctrl+Alt+Del"].tap()
    controls.tap()
    app.buttons["Settings"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    screenshot("settings", app)
    app.buttons["Done"].tap()
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(controls.waitForExistence(timeout: 5))
    screenshot("remote-landscape", app)
    XCUIDevice.shared.orientation = .portrait
  }
  @MainActor func testHoldEarlyReleaseDoesNotDisconnect() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    app.launchArguments = ["-onboardingVersion", "1"]
    app.launch()
    let controls = app.buttons["connection-controls"]
    XCTAssertTrue(controls.waitForExistence(timeout: 10))
    controls.tap()
    let close = app.buttons["Close connection"]
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    close.press(forDuration: 0.5)
    XCTAssertTrue(close.exists)
    close.press(forDuration: 2.2)
    XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
  }
  @MainActor func testFrozenFrameOCRSelectionAndRetry() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    app.launchArguments = ["-onboardingVersion", "1"]
    app.launch()
    let controls = app.buttons["connection-controls"]
    XCTAssertTrue(controls.waitForExistence(timeout: 10))
    controls.tap()
    app.buttons["OCR"].tap()
    let surface = app.descendants(matching: .any).matching(identifier: "Remote computer").firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    let height = surface.frame.width * 720 / 1280
    let top = (surface.frame.height - height) / 2
    let start = surface.coordinate(
      withNormalizedOffset: CGVector(dx: 0.03, dy: (top + height * 0.12) / surface.frame.height))
    let end = surface.coordinate(
      withNormalizedOffset: CGVector(dx: 0.97, dy: (top + height * 0.8) / surface.frame.height))
    start.press(forDuration: 0.1, thenDragTo: end)
    XCTAssertTrue(app.navigationBars["Recognized text"].waitForExistence(timeout: 15))
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Local test screen"))
        .firstMatch.exists)
    screenshot("ocr-result", app)
    app.buttons["Retry"].tap()
    XCTAssertTrue(app.staticTexts["Drag one finger to select text"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(controls.waitForExistence(timeout: 5))
  }
  @MainActor func testFirstUseGuideAtAccessibilityTextSize() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    app.launchArguments = [
      "-onboardingVersion", "0", "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    XCTAssertTrue(app.staticTexts["Point and click"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Next"].isHittable)
    screenshot("onboarding-accessibility-text", app)
    app.buttons["Next"].tap()
    app.buttons["Next"].tap()
    XCTAssertTrue(app.staticTexts["Scroll remotely"].exists)
    XCTAssertTrue(app.buttons["Next"].isHittable)
    app.buttons["Skip"].tap()
    XCTAssertTrue(app.buttons["connection-controls"].waitForExistence(timeout: 5))
  }
  @MainActor private func screenshot(_ name: String, _ app: XCUIApplication) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
