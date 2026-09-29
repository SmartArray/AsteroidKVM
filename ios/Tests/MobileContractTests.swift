import CometCore
import CometMedia
import CometSessionCore
import CoreGraphics
import XCTest

final class MobileContractTests: XCTestCase {
  func testInverseGeometryForAllRotationsAndPixelAspects() {
    for rotation in [0, 90, 180, 270] {
      for aspect in [0.8, 1.0, 1.4] {
        let geometry = DisplayGeometry(
          source: CGSize(width: 1920, height: 1080), viewport: CGSize(width: 390, height: 700),
          rotation: rotation, pixelAspect: aspect)
        var viewport = ViewportTransform()
        viewport.scale(by: 3, anchor: CGPoint(x: 195, y: 350), geometry: geometry)
        viewport.move(CGPoint(x: 40, y: -35), geometry: geometry)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
          let display = viewport.display(geometry.displayPoint(p), in: geometry.viewport)
          let result = geometry.sourcePoint(viewport.inverse(display, in: geometry.viewport))
          XCTAssertEqual(result.x, p.x, accuracy: 0.00001)
          XCTAssertEqual(result.y, p.y, accuracy: 0.00001)
        }
      }
    }
  }
  func testPinchAnchorAndBoundedPan() {
    let g = DisplayGeometry(
      source: CGSize(width: 800, height: 800), viewport: CGSize(width: 400, height: 400))
    var v = ViewportTransform()
    let anchor = CGPoint(x: 150, y: 120)
    let source = v.inverse(anchor, in: g.viewport)
    v.scale(by: 2, anchor: anchor, geometry: g)
    XCTAssertEqual(v.inverse(anchor, in: g.viewport), source)
    v.move(CGPoint(x: 9000, y: -9000), geometry: g)
    let rect = v.displayRect(g.imageRect, in: g.viewport)
    XCTAssertLessThanOrEqual(rect.minX, 0)
    XCTAssertGreaterThanOrEqual(rect.maxY, 400)
    v.scale(by: 100, anchor: anchor, geometry: g)
    XCTAssertEqual(v.zoom, 6)
    v.scale(by: 0.001, anchor: anchor, geometry: g)
    XCTAssertEqual(v.zoom, 1)
    XCTAssertEqual(v.pan, .zero)
  }
  func testOCRCropClampsSourceAfterLocalZoomAndRotation() {
    for rotation in [0, 90, 180, 270] {
      let g = DisplayGeometry(
        source: CGSize(width: 1280, height: 720), viewport: CGSize(width: 400, height: 600),
        rotation: rotation)
      var v = ViewportTransform()
      v.scale(by: 2, anchor: CGPoint(x: 200, y: 300), geometry: g)
      let a = v.display(g.displayPoint(CGPoint(x: 0.2, y: 0.25)), in: g.viewport)
      let b = v.display(g.displayPoint(CGPoint(x: 0.8, y: 0.75)), in: g.viewport)
      let crop = g.sourceCrop(from: v.inverse(a, in: g.viewport), to: v.inverse(b, in: g.viewport))
      XCTAssertEqual(crop.origin.x, 256, accuracy: 1)
      XCTAssertEqual(crop.origin.y, 180, accuracy: 1)
      XCTAssertEqual(crop.width, 768, accuracy: 2)
      XCTAssertEqual(crop.height, 360, accuracy: 2)
      XCTAssertTrue(CGRect(origin: .zero, size: g.source).contains(crop))
    }
  }
  func testRelativePacketsPreserveDistanceAndFractions() {
    var motion = MotionAccumulator()
    var all: [(Int, Int)] = []
    for _ in 0..<10 { all += motion.consume(dx: 30.25, dy: -27.75) }
    all += motion.consume(dx: 1000.5, dy: -1000.5)
    XCTAssertEqual(all.map(\.0).reduce(0, +), 1303)
    XCTAssertEqual(all.map(\.1).reduce(0, +), -1278)
    XCTAssertTrue(all.allSatisfy { abs($0.0) <= 127 && abs($0.1) <= 127 })
  }
  func testOwnershipTransitionsNeverResumePendingTap() {
    var state = TouchOwnership()
    XCTAssertEqual(state.begin(count: 1, permitted: true, selecting: false, inside: true), .mouse)
    XCTAssertEqual(
      state.begin(count: 2, permitted: true, selecting: false, inside: true), .viewport)
    XCTAssertEqual(state.begin(count: 3, permitted: true, selecting: false, inside: true), .scroll)
    state.end(remaining: 2)
    XCTAssertEqual(state.owner, .suppressed)
    XCTAssertEqual(
      state.begin(count: 3, permitted: true, selecting: false, inside: true), .suppressed)
    state.end(remaining: 0)
    XCTAssertEqual(state.owner, .idle)
    XCTAssertEqual(state.begin(count: 1, permitted: true, selecting: false, inside: true), .mouse)
  }
  func testChromeLetterboxSelectionAndDisconnectedOwnership() {
    for permitted in [true, false] {
      var s = TouchOwnership()
      XCTAssertEqual(
        s.begin(count: 1, permitted: permitted, selecting: false, inside: false), .suppressed)
    }
    var s = TouchOwnership()
    XCTAssertEqual(s.begin(count: 1, permitted: false, selecting: false, inside: true), .suppressed)
    s.cancel()
    XCTAssertEqual(s.begin(count: 1, permitted: true, selecting: true, inside: true), .selection)
    XCTAssertEqual(s.begin(count: 2, permitted: true, selecting: true, inside: true), .suppressed)
  }
  func testLegacyProfilesDefaultToAbsoluteAndFiftyMilliseconds() throws {
    let profile = ConnectionProfile(name: "Old", host: "localhost")
    let encoded = try JSONEncoder().encode(profile)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json.removeValue(forKey: "mobileMouseModeOverride")
    json.removeValue(forKey: "nativeTypingIntervalOverride")
    let old = try JSONDecoder().decode(
      ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: json))
    XCTAssertEqual(old.mobileMouseMode, .absolute)
    XCTAssertFalse(old.reverseScrolling)
    XCTAssertEqual(old.nativeTypingIntervalMilliseconds, 50)
    var updated = old
    updated.mobileMouseMode = .trackpad
    XCTAssertEqual(
      try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(updated))
        .mobileMouseMode, .trackpad)
  }
  @MainActor func testLocalFocusReleasePreservesQueuedPasteAndExactText() async {
    let record = Recorder()
    let output = HIDOutput(send: { await record.event($0) }, paste: { await record.paste($0, $1) })
    output.enqueue([.key("ShiftLeft", true), .button("left", true)])
    let text = " echo 'a'\n\tß👩🏽‍💻  "
    var completions = 0
    XCTAssertTrue(
      output.paste(text, keymap: "de") { result in if case .success = result { completions += 1 } })
    output.releasePhysicalInput()
    output.releasePhysicalInput()
    XCTAssertFalse(output.paste("duplicate", keymap: "en-us"))
    await output.flush()
    let values = await record.values()
    XCTAssertEqual(values.1, [text])
    XCTAssertEqual(values.2, ["de"])
    XCTAssertEqual(completions, 1)
    XCTAssertTrue(values.0.contains(.key("ShiftLeft", false)))
    XCTAssertTrue(values.0.contains(.button("left", false)))
  }
  @MainActor func testStopFinishesPasteOnceWithoutRetry() async {
    let record = Recorder()
    var completions = 0
    let output = HIDOutput(
      send: { _ in },
      paste: { text, keymap in
        await record.paste(text, keymap)
        try await Task.sleep(for: .seconds(30))
      })
    output.paste("one", keymap: "en-us") { _ in completions += 1 }
    await Task.yield()
    output.stop()
    await Task.yield()
    XCTAssertEqual(completions, 1)
    XCTAssertFalse(output.pasting)
    let stopped = await record.values()
    XCTAssertLessThanOrEqual(stopped.1.count, 1)
  }
  @MainActor func testSessionValidationAndMemoryDraftRecovery() async {
    let record = Recorder()
    let s = SessionCore(profile: ConnectionProfile(name: "Fixture", host: "fixture.invalid"))
    s.output = HIDOutput(
      send: { await record.event($0) }, paste: { _, _ in throw URLError(.timedOut) })
    s.output?.onPasteChanged = { [weak s] in s?.pasting = $0 }
    XCTAssertFalse(s.submitText("offline"))
    s.phase = .connected
    XCTAssertFalse(s.submitText(""))
    XCTAssertFalse(s.submitText(String(repeating: "a", count: 16385)))
    XCTAssertTrue(s.submitText("exact\ntext"))
    XCTAssertFalse(s.submitText("duplicate"))
    s.releaseCapture()
    await s.output?.flush()
    XCTAssertEqual(s.typingDraft, "exact\ntext")
    XCTAssertTrue(s.typingNotice?.contains("may have started") == true)
    XCTAssertFalse(s.pasting)
  }
  @MainActor func testSuccessfulTextClearsDraftAndShortcutReleasesReverseOrder() async {
    let record = Recorder()
    let s = SessionCore(profile: ConnectionProfile(name: "Fixture", host: "fixture.invalid"))
    s.output = HIDOutput(send: { await record.event($0) }, paste: { await record.paste($0, $1) })
    s.output?.onPasteChanged = { [weak s] in s?.pasting = $0 }
    s.phase = .connected
    XCTAssertTrue(s.submitText("ok"))
    await s.output?.flush()
    XCTAssertEqual(s.typingDraft, "")
    XCTAssertEqual(s.typingNotice, "Text sent")
    s.shortcut(["ControlLeft", "AltLeft", "Delete"])
    await s.output?.flush()
    let events = (await record.values()).0
    XCTAssertEqual(
      events,
      [
        .key("ControlLeft", true), .key("AltLeft", true), .key("Delete", true),
        .key("Delete", false), .key("AltLeft", false), .key("ControlLeft", false),
      ])
    s.phase = .disconnected
    s.shortcut(["KeyA"])
    await s.output?.flush()
    let final = await record.values()
    XCTAssertEqual(final.0, events)
  }
}
private actor Recorder {
  var events: [HIDEvent] = [], texts: [String] = [], keymaps: [String] = []
  func event(_ event: HIDEvent) { events.append(event) }
  func paste(_ text: String, _ keymap: String) {
    texts.append(text)
    keymaps.append(keymap)
  }
  func values() -> ([HIDEvent], [String], [String]) { (events, texts, keymaps) }
}
