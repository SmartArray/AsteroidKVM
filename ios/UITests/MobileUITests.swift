import Network
import XCTest

final class MobileUITests: XCTestCase {
  @MainActor func testWelcomeFirstLaunchSwipesCompletionAndReplay() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_RESET_WELCOME"] = "1"
    app.launchArguments = ["-appearance", "Light"]
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    assertPage(app, "welcome-progress", 1)
    XCTAssertTrue(app.staticTexts["BUILT FOR COMET KVM"].exists)
    XCTAssertFalse(app.buttons["Back"].isEnabled)
    screenshot("welcome-light-1", app)
    app.swipeRight()
    assertPage(app, "welcome-progress", 1)
    app.swipeLeft()
    assertPage(app, "welcome-progress", 2)
    screenshot("welcome-light-2", app)
    app.swipeRight()
    assertPage(app, "welcome-progress", 1)
    app.buttons["Next"].tap()
    assertPage(app, "welcome-progress", 2)
    app.buttons["Back"].tap()
    assertPage(app, "welcome-progress", 1)
    app.swipeLeft()
    app.swipeLeft()
    assertPage(app, "welcome-progress", 3)
    screenshot("welcome-light-3", app)
    app.swipeLeft()
    assertPage(app, "welcome-progress", 4)
    screenshot("welcome-light-4", app)
    app.swipeLeft()
    assertPage(app, "welcome-progress", 4)
    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
    app.terminate()
    app.launchEnvironment.removeValue(forKey: "ASTEROID_RESET_WELCOME")
    app.launch()
    XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.navigationBars["Welcome"].exists)
    app.buttons["More"].tap()
    app.buttons["Welcome tour"].tap()
    assertPage(app, "welcome-progress", 1)
    app.buttons["Skip"].tap()
    XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
  }

  @MainActor func testWelcomeDarkAppearanceSkipPersistenceAndLargeText() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_RESET_WELCOME"] = "1"
    app.launchArguments = ["-appearance", "Dark"]
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    for index in 1...4 {
      assertPage(app, "welcome-progress", index)
      let progress = app.descendants(matching: .any).matching(identifier: "welcome-progress")
        .firstMatch
      XCTAssertEqual(progress.value as? String, "Dark appearance")
      screenshot("welcome-dark-\(index)", app)
      if index < 4 { app.swipeLeft() }
    }
    XCUIDevice.shared.orientation = .landscapeLeft
    Thread.sleep(forTimeInterval: 1)
    XCTAssertTrue(app.buttons["Get Started"].isHittable)
    screenshot("welcome-dark-landscape", app)
    app.buttons["Skip"].tap()
    app.terminate()
    app.launchEnvironment.removeValue(forKey: "ASTEROID_RESET_WELCOME")
    app.launch()
    XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
    app.terminate()
    XCUIDevice.shared.orientation = .portrait
    app.launchArguments += [
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    app.buttons["More"].tap()
    app.buttons["Welcome tour"].tap()
    assertPage(app, "welcome-progress", 1)
    screenshot("welcome-accessibility", app)
    app.swipeUp()
    screenshot("welcome-scrolled-header", app)
    for _ in 0..<3 { app.buttons["Next"].tap() }
    assertPage(app, "welcome-progress", 4)
    XCTAssertTrue(app.buttons["Get Started"].isHittable)
    app.buttons["Get Started"].tap()
  }

  @MainActor func testGestureGuideSwipingAndVerticalScrolling() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    app.launchEnvironment["ASTEROID_RESET_WELCOME"] = "1"
    app.launchArguments = ["-onboardingVersion", "0"]
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    assertPage(app, "welcome-progress", 1)
    app.buttons["Skip"].tap()
    // The app welcome must not consume the separate first-connection gesture lesson.
    assertPage(app, "guide-progress", 1)
    app.swipeRight()
    assertPage(app, "guide-progress", 1)
    app.swipeLeft()
    assertPage(app, "guide-progress", 2)
    app.swipeRight()
    assertPage(app, "guide-progress", 1)
    app.swipeUp()
    assertPage(app, "guide-progress", 1)
    app.swipeLeft()
    app.swipeLeft()
    assertPage(app, "guide-progress", 3)
    app.swipeLeft()
    assertPage(app, "guide-progress", 4)
    app.buttons["guide-controls-preview"].tap()
    XCTAssertTrue(app.staticTexts["A shortcut to everything."].waitForExistence(timeout: 5))
    app.swipeLeft()
    assertPage(app, "guide-progress", 4)
    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.buttons["connection-controls"].waitForExistence(timeout: 5))
  }

  @MainActor private func assertPage(_ app: XCUIApplication, _ id: String, _ number: Int) {
    let progress = app.descendants(matching: .any).matching(identifier: id).firstMatch
    XCTAssertTrue(progress.waitForExistence(timeout: 10))
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Page \(number) of 4"), object: progress
          )
        ], timeout: 5) == .completed)
  }

  @MainActor func testGestureGuideLightAndDarkAppearances() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    XCUIDevice.shared.orientation = .portrait
    for theme in ["Light", "Dark"] {
      app.launchArguments = [
        "-welcomeVersion", "1", "-onboardingVersion", "0", "-appearance", theme,
      ]
      app.launch()
      let titles = [
        "Point and click", "Pan and zoom", "Scroll remotely", "Your controls, within reach",
      ]
      for (index, title) in titles.enumerated() {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        let next = app.buttons[index == 3 ? "Get Started" : "Next"]
        XCTAssertTrue(next.isHittable)
        let progress = app.descendants(matching: .any).matching(identifier: "guide-progress")
          .firstMatch
        XCTAssertEqual(progress.value as? String, "\(theme) appearance")
        screenshot("guide-\(theme.lowercased())-\(index + 1)", app)
        if index == 0 {
          XCUIDevice.shared.orientation = .landscapeLeft
          XCTAssertTrue(next.isHittable)
          // The orientation notification precedes the system's rotation animation finishing.
          Thread.sleep(forTimeInterval: 1)
          screenshot("guide-\(theme.lowercased())-landscape", app)
          XCUIDevice.shared.orientation = .portrait
          Thread.sleep(forTimeInterval: 1)
        }
        if index == 3 {
          app.buttons["guide-controls-preview"].tap()
          XCTAssertTrue(app.staticTexts["A shortcut to everything."].waitForExistence(timeout: 5))
        }
        next.tap()
      }
      XCTAssertTrue(app.buttons["connection-controls"].waitForExistence(timeout: 5))
    }
  }

  @MainActor func testPersistentKeyboardResizesCanvasTypesAndDismisses() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    app.launchArguments = [
      "-welcomeVersion", "1", "-onboardingVersion", "1", "-floatingCorner", "3",
    ]
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    let controls = app.buttons["connection-controls"]
    XCTAssertTrue(controls.waitForExistence(timeout: 10))
    let surface = app.descendants(matching: .any).matching(identifier: "Remote computer").firstMatch
    surface.pinch(withScale: 3, velocity: 1)
    let savedViewport = (surface.value as? String)?.components(separatedBy: "; ").prefix(2)
      .joined(separator: "; ") ?? "missing"
    XCTAssertFalse(savedViewport.hasPrefix("Zoom 100 percent"))
    let fullHeight = surface.frame.height
    controls.tap()
    app.buttons["Keyboard"].tap()
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    // A newly booted simulator can show Apple's first-use slide-to-type lesson.
    if app.otherElements["UIContinuousPathIntroductionView"].exists {
      app.buttons["Continue"].tap()
    }
    XCTAssertEqual(controls.label, "Dismiss keyboard")
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in surface.frame.height < fullHeight - 100 }, object: nil
          )
        ], timeout: 5) == .completed, "\(surface.value ?? "missing surface")")
    XCTAssertLessThanOrEqual(surface.frame.maxY, keyboard.frame.minY + 2)
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: keyboard.keys["a"]
          )
        ], timeout: 10) == .completed)
    XCTAssertTrue((surface.value as? String)?.hasPrefix(savedViewport) == true,
      "Opening the keyboard must preserve zoom and center: \(surface.value ?? "missing")")
    screenshot("persistent-keyboard-portrait", app)
    keyboard.keys["a"].tap()
    keyboard.keys["b"].tap()
    keyboard.keys["delete"].tap()
    keyboard.buttons["Return"].tap()
    let sent = NSPredicate(
      format: "value CONTAINS %@ AND value CONTAINS %@", "text=ab",
      "Backspace:down,Backspace:up,Enter:down,Enter:up")
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: sent, object: surface)], timeout: 12)
        == .completed, "\(surface.value ?? "missing surface")")
    surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "leftDown=1 leftUp=1"),
            object: surface
          )
        ], timeout: 5) == .completed)
    XCTAssertTrue(keyboard.exists, "Remote clicks must keep the keyboard open")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
              app.frame.width > app.frame.height && surface.frame.width > surface.frame.height
                && controls.frame.maxX <= app.frame.maxX
            }, object: nil
          )
        ], timeout: 5) == .completed)
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    XCTAssertLessThanOrEqual(surface.frame.maxY, keyboard.frame.minY + 2)
    screenshot("persistent-keyboard-landscape", app)
    controls.tap()
    XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
    XCTAssertEqual(controls.label, "Connection controls")
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in abs(surface.frame.height - fullHeight) < 3 },
            object: nil
          )
        ], timeout: 5) == .completed)
    XCTAssertTrue((surface.value as? String)?.hasPrefix(savedViewport) == true,
      "Dismissing the keyboard and rotating back must restore the viewport")
    // Reopening exercises responder ownership after a complete show/hide cycle.
    controls.tap()
    app.buttons["Keyboard"].tap()
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    controls.tap()
    XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
  }

  @MainActor func testConnectionProbeSuccessFailureAndEditedCredentials() throws {
    let server = try ConnectionTestServer()
    defer { server.close() }
    let app = XCUIApplication()
    app.launchArguments = ["-welcomeVersion", "1", "-onboardingVersion", "1"]
    app.launch()
    fillConnectionEditor(app, port: server.port, name: "Connection test")
    let password = app.secureTextFields["connection-password"]
    replaceText(password, with: "wrong-password")
    finishEditing(app)
    let probe = app.buttons["test-connection"]
    probe.tap()
    XCTAssertTrue(app.staticTexts["connection-test-error"].waitForExistence(timeout: 10))
    XCTAssertEqual(probe.label, "Connection failed — try again")
    screenshot("connection-test-failed", app)
    replaceText(password, with: "test-password")
    finishEditing(app)
    XCTAssertEqual(probe.label, "Test connection")
    probe.tap()
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Connection successful"), object: probe
          )
        ], timeout: 15) == .completed)
    XCTAssertTrue(server.paths.contains("/api/auth/check"))
    XCTAssertTrue(server.paths.contains("/api/hid"))
    XCTAssertTrue(server.paths.contains("/api/auth/logout"))
    XCTAssertFalse(server.paths.contains("/api/ws"))
    screenshot("connection-test-success", app)
    replaceText(password, with: "changed-password")
    finishEditing(app)
    XCTAssertEqual(probe.label, "Test connection")
    app.buttons["Cancel"].tap()
  }

  @MainActor func testOnboardingDelaysNetworkUntilDismissed() throws {
    let server = try ConnectionTestServer()
    defer { server.close() }
    let app = XCUIApplication()
    app.launchArguments = ["-welcomeVersion", "1", "-onboardingVersion", "0"]
    app.launch()
    let name = "Onboarding \(UUID().uuidString.prefix(8))"
    fillConnectionEditor(app, port: server.port, name: name)
    app.buttons["Save"].tap()
    let row = app.staticTexts[name]
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    row.tap()
    let password = app.secureTextFields.firstMatch
    XCTAssertTrue(password.waitForExistence(timeout: 5))
    password.tap()
    password.typeText("wrong-password")
    app.buttons["Connect"].tap()
    XCTAssertTrue(app.staticTexts["Point and click"].waitForExistence(timeout: 5))
    for title in ["Pan and zoom", "Scroll remotely", "Your controls, within reach"] {
      XCTAssertTrue(
        server.paths.isEmpty, "No sign-in or certificate request before the guide finishes")
      app.buttons["Next"].tap()
      XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
      XCTAssertEqual(app.alerts.count, 0)
    }
    XCTAssertTrue(server.paths.isEmpty)
    app.buttons["Get Started"].tap()
    XCTAssertTrue(app.alerts["Authentication required"].waitForExistence(timeout: 10))
    XCTAssertTrue(server.paths.contains("/api/auth/login"))
    app.alerts.buttons["Cancel"].tap()
    app.buttons["connection-controls"].tap()
    app.buttons["Close connection"].press(forDuration: 1.2)
    XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
    row.swipeLeft()
    app.buttons["Delete"].tap()
    XCTAssertTrue(row.waitForNonExistence(timeout: 5))
  }

  @MainActor func testTouchesWorkAfterFirstUseGuideWithoutReconnect() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    app.launchArguments = ["-welcomeVersion", "1", "-onboardingVersion", "0"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Point and click"].waitForExistence(timeout: 10))
    app.buttons["Skip"].tap()
    let surface = app.descendants(matching: .any).matching(identifier: "Remote computer").firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "leftDown=1 leftUp=1"),
            object: surface
          )
        ], timeout: 5) == .completed)
  }

  @MainActor private func fillConnectionEditor(_ app: XCUIApplication, port: UInt16, name: String) {
    XCUIDevice.shared.orientation = .portrait
    app.buttons["Add connection"].firstMatch.tap()
    let field = app.textFields["connection-name"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(name)
    app.textFields["connection-host"].tap()
    app.textFields["connection-host"].typeText("127.0.0.1")
    finishEditing(app)
    app.buttons["connection-protocol"].tap()
    app.buttons["HTTP"].tap()
    XCTAssertTrue(app.buttons["connection-protocol"].label.contains("HTTP"))
    replaceText(app.textFields["connection-port"], with: String(port))
  }

  @MainActor private func replaceText(_ field: XCUIElement, with text: String) {
    field.tap()
    let count = (field.value as? String)?.count ?? 0
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + text)
  }

  @MainActor private func finishEditing(_ app: XCUIApplication) {
    app.buttons["editor-done-typing"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
  }

  @MainActor func testRemoteTouchesReachSurfaceWithFloatingMenuVisible() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    app.launchArguments = [
      "-welcomeVersion", "1", "-onboardingVersion", "1", "-floatingCorner", "3",
    ]
    app.launch()
    let controls = app.buttons["connection-controls"]
    XCTAssertTrue(controls.waitForExistence(timeout: 10))
    let surface = app.descendants(matching: .any).matching(identifier: "Remote computer").firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let clicked = NSPredicate(format: "value CONTAINS %@", "leftDown=1 leftUp=1")
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: clicked, object: surface)], timeout: 5)
        == .completed, "The visible menu must not swallow remote clicks: \(surface.value ?? "nil")")
    surface.pinch(withScale: 2, velocity: 1)
    XCTAssertFalse((surface.value as? String)?.contains("Zoom 100 percent") == true)
    // Local pinch must never become an extra remote click.
    XCTAssertTrue((surface.value as? String)?.contains("leftDown=1 leftUp=1") == true)
    controls.tap()
    XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    let clickedAgain = NSPredicate(format: "value CONTAINS %@", "leftDown=2 leftUp=2")
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: clickedAgain, object: surface)], timeout: 5)
        == .completed)
  }

  @MainActor func testSpecialKeysAndShortcutsDeliverBalancedEvents() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    app.launchArguments = ["-welcomeVersion", "1", "-onboardingVersion", "1"]
    app.launch()
    let controls = app.buttons["connection-controls"]
    XCTAssertTrue(controls.waitForExistence(timeout: 10))
    controls.tap()
    app.buttons["Special keys"].tap()
    XCTAssertTrue(app.buttons["Escape"].waitForExistence(timeout: 5))
    app.buttons["Escape"].tap()
    let surface = app.descendants(matching: .any).matching(identifier: "Remote computer").firstMatch
    let escape = NSPredicate(format: "value CONTAINS %@", "Escape:down,Escape:up")
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: escape, object: surface)], timeout: 5)
        == .completed)
    controls.tap()
    app.buttons["Shortcuts"].tap()
    XCTAssertTrue(app.buttons["Ctrl+Alt+Del"].waitForExistence(timeout: 5))
    app.buttons["Ctrl+Alt+Del"].tap()
    let shortcut = NSPredicate(
      format: "value CONTAINS %@",
      "ControlLeft:down,AltLeft:down,Delete:down,Delete:up,AltLeft:up,ControlLeft:up")
    XCTAssertTrue(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: shortcut, object: surface)], timeout: 5)
        == .completed)
  }

  @MainActor func testFloatingMenuSnapsAfterRepeatedDrags() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    app.launchArguments = [
      "-welcomeVersion", "1", "-onboardingVersion", "1", "-floatingCorner", "3",
    ]
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    let controls = app.buttons["connection-controls"]
    XCTAssertTrue(controls.waitForExistence(timeout: 10))
    let surface = app.descendants(matching: .any).matching(identifier: "Remote computer").firstMatch
    let frame = surface.frame
    for destination in [
      CGVector(dx: 0.2, dy: 0.2), CGVector(dx: 0.8, dy: 0.2),
      CGVector(dx: 0.2, dy: 0.2), CGVector(dx: 0.8, dy: 0.2),
      CGVector(dx: 0.8, dy: 0.8), CGVector(dx: 0.2, dy: 0.8),
      CGVector(dx: 0.8, dy: 0.8), CGVector(dx: 0.2, dy: 0.8),
      CGVector(dx: 0.3, dy: 0.7),
    ] {
      controls.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
        forDuration: 0.1, thenDragTo: surface.coordinate(withNormalizedOffset: destination))
      let expectedX = destination.dx > 0.5 ? frame.maxX - 38 : frame.minX + 38
      XCTAssertEqual(controls.frame.midX, expectedX, accuracy: 3)
      let expectedY = destination.dy > 0.5 ? frame.maxY - 38 : frame.minY + 38
      XCTAssertEqual(controls.frame.midY, expectedY, accuracy: 3)
      XCTAssertTrue(frame.contains(controls.frame), "The button must remain inside the canvas")
      XCTAssertTrue(controls.isHittable)
    }
    controls.tap()
    XCTAssertTrue(app.buttons["Type"].waitForExistence(timeout: 5))
  }

  @MainActor func testSaveEditAndDeleteWithoutRememberingPassword() {
    let app = XCUIApplication()
    app.launchArguments = ["-welcomeVersion", "1", "-onboardingVersion", "1"]
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
    app.launchArguments = ["-welcomeVersion", "1", "-onboardingVersion", "0"]
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
    app.launchArguments = ["-welcomeVersion", "1", "-onboardingVersion", "1"]
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
    XCTAssertTrue(app.navigationBars["Special keys"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(controls.waitForExistence(timeout: 5))
    controls.tap()
    app.buttons["Shortcuts"].tap()
    XCTAssertTrue(app.buttons["Ctrl+Alt+Del"].waitForExistence(timeout: 5))
    app.buttons["Ctrl+Alt+Del"].tap()
    XCTAssertTrue(app.navigationBars["Shortcuts"].waitForNonExistence(timeout: 5))
    controls.tap()
    app.buttons["Settings"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.switches["Reverse scrolling"].value as? String, "0")
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
    app.launchArguments = ["-welcomeVersion", "1", "-onboardingVersion", "1"]
    app.launch()
    let controls = app.buttons["connection-controls"]
    XCTAssertTrue(controls.waitForExistence(timeout: 10))
    controls.tap()
    let close = app.buttons["Close connection"]
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    close.press(forDuration: 0.5)
    XCTAssertTrue(close.exists)
    close.press(forDuration: 1.2)
    XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Type"].exists)
    XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
    // The dismissed session menu must not cover or block the connection list.
    app.buttons["Add connection"].firstMatch.tap()
    XCTAssertTrue(app.textFields["connection-name"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
  }
  @MainActor func testFrozenFrameOCRSelectionAndRetry() {
    let app = XCUIApplication()
    app.launchEnvironment["ASTEROID_UI_FIXTURE"] = "1"
    app.launchArguments = ["-welcomeVersion", "1", "-onboardingVersion", "1"]
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
      "-welcomeVersion", "1",
      "-onboardingVersion", "0", "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    XCTAssertTrue(app.staticTexts["Point and click"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Next"].isHittable)
    screenshot("onboarding-accessibility-text", app)
    app.swipeUp()
    screenshot("guide-scrolled-header", app)
    app.swipeDown()
    app.buttons["Next"].tap()
    assertPage(app, "guide-progress", 2)
    app.buttons["Next"].tap()
    assertPage(app, "guide-progress", 3)
    XCTAssertTrue(app.buttons["Next"].isHittable)
    app.buttons["Next"].tap()
    XCTAssertTrue(app.buttons["Get Started"].isHittable)
    screenshot("onboarding-controls-accessibility-text", app)
    app.buttons["Skip"].tap()
    XCTAssertTrue(app.buttons["connection-controls"].waitForExistence(timeout: 5))
  }
  @MainActor private func screenshot(_ name: String, _ app: XCUIApplication) {
    // Capture the screen rather than an app crop, which can be misaligned after rotation.
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

// A loopback HTTP KVM exercises the actual login/discovery transport without any appliance or secrets.
private final class ConnectionTestServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "ConnectionTestServer")
  private let lock = NSLock()
  private var requests: [String] = []
  var port: UInt16 { listener.port!.rawValue }
  var paths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
  init() throws {
    listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      connection.start(queue: self.queue)
      self.receive(connection, data: Data())
    }
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.signal() }
      if case .failed = state { ready.signal() }
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port, port.rawValue > 0
    else {
      listener.cancel()
      throw NSError(domain: "ConnectionTestServer", code: 1)
    }
  }
  func close() { listener.cancel() }
  private func receive(_ connection: NWConnection, data: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] chunk, _, done, error in
      guard let self, error == nil, let chunk else {
        connection.cancel()
        return
      }
      let data = data + chunk
      guard let text = String(data: data, encoding: .utf8),
        let boundary = text.range(of: "\r\n\r\n")
      else {
        if done { connection.cancel() } else { self.receive(connection, data: data) }
        return
      }
      let header = String(text[..<boundary.lowerBound])
      let body = String(text[boundary.upperBound...])
      let length =
        header.components(separatedBy: "\r\n").first {
          $0.lowercased().hasPrefix("content-length:")
        }.flatMap { Int($0.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)) } ?? 0
      guard body.utf8.count >= length else {
        self.receive(connection, data: data)
        return
      }
      let path =
        header.components(separatedBy: " ").dropFirst().first?.components(separatedBy: "?").first
        ?? ""
      self.lock.lock()
      self.requests.append(path)
      self.lock.unlock()
      var status = 200
      var result: [String: Any] = [:]
      if path == "/api/auth/login" {
        if body.contains("passwd=test-password") {
          result = ["token": "ui-test-token"]
        } else {
          status = 401
        }
      } else if !header.contains("ui-test-token") {
        status = 401
      } else if ![
        "/api/auth/check", "/api/auth/logout", "/api/hid", "/api/hid/keymaps", "/api/streamer",
      ].contains(path) {
        status = 404
      }
      let payload = try! JSONSerialization.data(withJSONObject: [
        "ok": status == 200, "result": result,
      ])
      let response =
        Data(
          "HTTP/1.1 \(status) Result\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
            .utf8) + payload
      connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
  }
}
