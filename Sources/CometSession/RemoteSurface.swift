// Adapt AppKit events to the ordered input engine and retain a stable native Metal surface.
import AppKit
import Combine
import CometCore
import CometMedia
import IOKit.hidsystem
import MetalKit

@MainActor public final class RemoteSurface: NSView, @preconcurrency NSTextInputClient {
  // AppKit keeps unfinished text local; only insertText commits enter the ordered HID queue.
  private var markedInput = NSAttributedString(string: "")
  private var markedSelection = NSRange(location: 0, length: 0)
  private var interpretingEvent: NSEvent?
  private var captureObservation: AnyCancellable?
  private let compositionLabel = NSTextField(labelWithString: "")
  private let session: SessionController
  private var metalView: MTKView?
  private var renderer: MetalVideoRenderer?
  private let selectionLayer = CAShapeLayer()
  private let clickPreviewView = ClickPreviewView()
  private var geometry: DisplayGeometry?
  private var frozen: VideoFrame?
  private var selectionStart: CGPoint?
  private var selectionGeometry: DisplayGeometry?
  private var observers: [NSObjectProtocol] = []

  // Native popovers and sheets retain local focus; automatic capture occurs only on activation or connection.
  public var allowsAutomaticCapture = true
  private var wasSessionActive = false
  private var capsLock = false
  private var lastMouseTime = 0.0
  private var tracking: NSTrackingArea?
  private var fullscreenDelegate: FullscreenWindowDelegate?
  public override var isFlipped: Bool { true }
  public override var acceptsFirstResponder: Bool { true }

  // Route pointer events to the capture adapter instead of the passive Metal child view.
  public override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

  // Keep the MTKView instance and decoder sink intact across fullscreen and SwiftUI updates.
  public init(session: SessionController) {
    self.session = session
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    setAccessibilityElement(true)
    setAccessibilityIdentifier("remote-display")
    setAccessibilityLabel("Remote display")
    setAccessibilityRole(.group)

    // A local preedit indicator makes dead keys visible without modifying remote pixels or screenshots.
    compositionLabel.font = .systemFont(ofSize: 16)
    compositionLabel.textColor = .labelColor
    compositionLabel.backgroundColor = .windowBackgroundColor
    compositionLabel.drawsBackground = true
    compositionLabel.isHidden = true
    compositionLabel.setAccessibilityIdentifier("native-composition")
    captureObservation = session.$captured.sink { [weak self] captured in
      if !captured { self?.cancelComposition() }
    }
    guard let device = MTLCreateSystemDefaultDevice() else {
      session.message = "This Mac has no available Metal device."
      return
    }
    do {
      let renderer = try MetalVideoRenderer(mailbox: session.mailbox, device: device)
      self.renderer = renderer
      renderer.onGeometry = { [weak self] geometry in self?.geometryChanged(geometry) }
      renderer.onError = { [weak session] message in
        if session?.message != message { session?.message = message }
      }
      let view = MTKView(frame: bounds, device: device)
      metalView = view
      view.delegate = renderer
      view.colorPixelFormat = .bgra8Unorm
      view.clearColor = MTLClearColorMake(0, 0, 0, 1)
      view.framebufferOnly = true
      view.preferredFramesPerSecond = 60
      view.autoresizingMask = [.width, .height]
      addSubview(view)

      // Keep an unfilled gray outline above Metal's backing layer so the selected text stays visible.
      selectionLayer.strokeColor = NSColor.gray.cgColor
      selectionLayer.fillColor = NSColor.clear.cgColor
      selectionLayer.lineWidth = 1.5
      selectionLayer.zPosition = 1
      selectionLayer.frame = bounds
      selectionLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
      layer?.addSublayer(selectionLayer)

      // Composite agent hints above video without touching decoded frames or screenshots sent to Codex.
      addSubview(clickPreviewView)
      addSubview(compositionLabel)
    } catch { session.message = error.localizedDescription }
  }
  public required init?(coder: NSCoder) {
    fatalError("RemoteSurface is constructed programmatically")
  }

  // Resize the existing Metal surface to the AppKit bounds without changing media ownership.
  public override func layout() {
    super.layout()
    metalView?.frame = bounds

    // Only a real bounds change invalidates a drag; ordinary SwiftUI layout passes must preserve it.
    if selectionLayer.frame != bounds {
      if selectionStart != nil { cancelSelection() }
      selectionLayer.frame = bounds
    }
  }

  // Install window-scoped lifecycle observers and native fullscreen behavior.
  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    cancelComposition()
    guard let window else { return }
    window.acceptsMouseMovedEvents = true
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.title = session.profile.name
    window.setFrameAutosaveName("Comet-\(session.id)")
    window.toolbarStyle = .unifiedCompact
    if !(window.delegate is FullscreenWindowDelegate) {
      let delegate = FullscreenWindowDelegate(original: window.delegate)
      fullscreenDelegate = delegate
      window.delegate = delegate
    }

    // React to both window switching and returning to the app with its display window already selected.
    for (name, object) in [
      (NSWindow.didBecomeKeyNotification, window as AnyObject?),
      (NSApplication.didBecomeActiveNotification, nil),
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
          [weak self] _ in
          Task { @MainActor in self?.focusRemoteDisplay() }
        })
    }
    Task { @MainActor [weak self] in self?.focusRemoteDisplay() }

    for name in [
      NSWindow.didResignKeyNotification, NSWindow.willEnterFullScreenNotification,
      NSWindow.willExitFullScreenNotification,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
          [weak self] _ in
          Task { @MainActor in
            self?.session.releaseCapture()
            self?.cancelSelection()
          }
        })
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.cancelSelection()
          await self.session.disconnect()
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.session.releaseCapture()
          self?.cancelSelection()
        }
      })
  }

  // Give the active display keyboard focus and use the session registry to release input on other connections.
  private func focusRemoteDisplay() {
    guard allowsAutomaticCapture, let window, window.isKeyWindow, NSApp.isActive,
      window.attachedSheet == nil, !window.isMiniaturized, session.active,
      session.pendingCertificate == nil, session.ocrText == nil,
      !session.ocrSelecting, !session.ocrBusy, !session.pasting
    else { return }
    if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return }
    guard window.makeFirstResponder(self) else { return }
    if !session.captured { session.capture() }
  }

  // Track only this view in its active window so unfocused sessions cannot capture pointer motion.
  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [
        .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .cursorUpdate,
      ], owner: self)
    tracking = area
    addTrackingArea(area)
  }

  // Use a crosshair only during local OCR selection and restore the normal pointer otherwise.
  public override func cursorUpdate(with event: NSEvent) {
    session.ocrSelecting ? NSCursor.crosshair.set() : NSCursor.arrow.set()
  }

  // Release remote input before another local control becomes the editing target.
  public override func resignFirstResponder() -> Bool {
    session.releaseCapture()
    cancelSelection()
    return true
  }

  // Balance held input at the view edge while keeping keyboard capture tied to window focus, not pointer position.
  public override func mouseExited(with event: NSEvent) {
    if canSend {
      _ = session.input.releaseAll()
      session.output?.releaseAll()
    }
    NSCursor.arrow.set()
  }

  // Restore the selection cursor on re-entry without requiring another toolbar click.
  public override func mouseEntered(with event: NSEvent) {
    cursorUpdate(with: event)
  }

  // Remove observers and selection resources when the surface is no longer presented.
  public func teardown() {
    allowsAutomaticCapture = false
    cancelSelection()
    session.releaseCapture()
    metalView?.isPaused = true
    metalView?.delegate = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
  }

  // A frozen frame and fixed geometry make OCR selection deterministic while the stream continues receiving.
  public func synchronize() {
    // Defer capture until SwiftUI finishes updating; repeated video/state updates must not undo an explicit release.
    let becameActive = session.active && !wasSessionActive
    wasSessionActive = session.active
    if becameActive { Task { @MainActor [weak self] in self?.focusRemoteDisplay() } }

    // Clear unfinished composition whenever the active input mode no longer accepts it.
    if !canSend || !session.input.nativeLayout || !session.input.mappedTextSupported {
      cancelComposition()
    }
    updateClickPreview()
    renderer?.scaleMode = session.profile.scaleMode
    renderer?.rotation = session.profile.rotation
    if session.ocrSelecting && frozen == nil {
      frozen = session.mailbox.snapshot()
      renderer?.frozenFrame = frozen
      window?.makeFirstResponder(self)
      NSCursor.crosshair.set()
    } else if !session.ocrSelecting && frozen != nil {
      clearSelection()
    }
  }

  // Cancel selection when its source-to-screen transform changes to prevent incorrect crops.
  private func geometryChanged(_ new: DisplayGeometry) {
    if let selectionGeometry, selectionGeometry != new { cancelSelection() }
    geometry = new
    updateClickPreview()
  }

  // Apply the same rotation, pixel aspect, and letterboxing used for the video and human pointer input.
  private func updateClickPreview() {
    guard let preview = session.agentClickPreview, let geometry, geometry.valid else {
      clickPreviewView.show(at: nil)
      return
    }
    let point = geometry.displayPoint(CGPoint(x: preview.x, y: preview.y))
    let visible = geometry.visibleRect
    // Include the last source row and column; their normalized coordinates land on the rectangle's maximum edges.
    let inside =
      point.x >= visible.minX && point.x <= visible.maxX
      && point.y >= visible.minY && point.y <= visible.maxY
    clickPreviewView.show(at: inside ? point : nil)
  }

  // Discard the retained selection frame and restore ordinary pointer behavior.
  private func clearSelection() {
    frozen = nil
    renderer?.frozenFrame = nil
    selectionStart = nil
    selectionGeometry = nil
    selectionLayer.path = nil
    NSCursor.arrow.set()
  }

  // End both the local overlay and session selection state together.
  private func cancelSelection() {
    clearSelection()
    session.cancelOCR()
  }
  private var canSend: Bool {
    session.captured && window?.isKeyWindow == true && window?.firstResponder === self
      && !session.pasting && !session.ocrSelecting
  }

  // Convert AppKit window coordinates into the same local coordinates used by rendering.
  private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

  // OCR drags clamp both selection geometry and the visible cursor, with no persistent pointer lock.
  public override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    guard let geometry else { return }
    let p = point(event)
    if session.ocrSelecting {
      guard geometry.visibleRect.contains(p) else { return }
      selectionStart = p
      selectionGeometry = geometry
      updateSelection(event)
      return
    }
    guard geometry.visibleRect.contains(p) else {
      session.releaseCapture()
      return
    }
    if !session.captured {
      session.capture()
      return
    }
    sendMouse(event, button: "left", down: true)
  }

  // Continue OCR selection locally or forward captured motion through the shared geometry.
  public override func mouseDragged(with event: NSEvent) {
    if selectionStart != nil { updateSelection(event) } else { sendMotion(event) }
  }

  // Finish the active local selection or balance a forwarded remote mouse press.
  public override func mouseUp(with event: NSEvent) {
    if let start = selectionStart, let frozen, let geometry = selectionGeometry {
      let crop = geometry.sourceCrop(from: start, to: point(event))
      clearSelection()
      session.recognize(frame: frozen, crop: crop)
      return
    }
    sendMouse(event, button: "left", down: false)
  }

  // Clamp both the drag rectangle and cursor to the visible remote image.
  private func updateSelection(_ event: NSEvent) {
    guard let geometry = selectionGeometry, let start = selectionStart else { return }
    let raw = point(event)
    let end = geometry.clamp(raw)
    selectionLayer.path = CGPath(
      rect: CGRect(
        x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
        height: abs(end.y - start.y)), transform: nil)
    if raw != end, let window, let main = NSScreen.screens.first {
      let screen = window.convertPoint(toScreen: convert(end, to: nil))
      CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: main.frame.maxY - screen.y))
    }
  }

  // Forward a right-button press only through the focused capture gate.
  public override func rightMouseDown(with event: NSEvent) {
    sendMouse(event, button: "right", down: true)
  }

  // Balance a right-button release through the same capture policy.
  public override func rightMouseUp(with event: NSEvent) {
    sendMouse(event, button: "right", down: false)
  }

  // Translate the middle button through the session’s ordered HID queue.
  public override func otherMouseDown(with event: NSEvent) {
    sendMouse(event, button: "middle", down: true)
  }

  // Release the middle button without bypassing focus checks.
  public override func otherMouseUp(with event: NSEvent) {
    sendMouse(event, button: "middle", down: false)
  }

  // Reuse captured motion handling while the right mouse button is held.
  public override func rightMouseDragged(with event: NSEvent) { sendMotion(event) }

  // Reuse captured motion handling while another mouse button is held.
  public override func otherMouseDragged(with event: NSEvent) { sendMotion(event) }

  // Apply the same polling, focus, and coordinate rules to ordinary pointer movement.
  public override func mouseMoved(with event: NSEvent) { sendMotion(event) }

  // Flush deferred modifiers immediately before forwarding a captured mouse button.
  private func sendMouse(_ event: NSEvent, button: String, down: Bool) {
    guard canSend else { return }
    session.output?.enqueue(
      session.input.flushModifiers(modifiers(event)) + [.button(button, down)])
  }

  // Map absolute positions or relative deltas using the current display geometry and local preferences.
  private func sendMotion(_ event: NSEvent) {
    guard canSend, session.profile.mouseEnabled, let geometry else { return }
    let interval = max(1, session.profile.mousePollingMilliseconds) / 1000
    guard event.timestamp - lastMouseTime >= interval else { return }
    lastMouseTime = event.timestamp
    if session.state.system["absolute_mouse"].bool != false {
      let (x, y) = geometry.hidPoint(point(event))
      session.output?.enqueue([
        HIDEvent("mouse_move", ["to": .object(["x": .number(Double(x)), "y": .number(Double(y))])])
      ])
    } else {
      delta(
        "mouse_relative", x: event.deltaX * session.profile.mouseSensitivity,
        y: event.deltaY * session.profile.mouseSensitivity)
    }
  }

  // Apply local scroll preferences before encoding bounded Comet wheel deltas.
  public override func scrollWheel(with event: NSEvent) {
    guard canSend, session.profile.mouseEnabled else { return }
    delta(
      "mouse_wheel", x: event.scrollingDeltaX * session.profile.scrollSensitivity,
      y: (session.profile.reverseScrolling ? 1 : -1) * event.scrollingDeltaY
        * session.profile.scrollSensitivity)
  }

  // Clamp relative motion to the daemon’s signed-byte wire range.
  private func delta(_ type: String, x: Double, y: Double) {
    let dx = min(127, max(-127, x.rounded()))
    let dy = min(127, max(-127, y.rounded()))
    session.output?.enqueue([
      HIDEvent(
        type, ["delta": .object(["x": .number(dx), "y": .number(dy)]), "squash": .bool(false)])
    ])
  }

  // Local escape routes precede remote shortcuts; menus and local text fields retain normal editing behavior.
  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.isKeyWindow == true, window?.firstResponder === self else { return false }
    if localCommand(event) { return true }
    if canSend, event.modifierFlags.contains(.command) {
      keyDown(with: event)
      return true
    }
    return false
  }

  // Reserve escape routes and local application commands before considering remote input.
  private func localCommand(_ event: NSEvent) -> Bool {
    let flags = modifiers(event)
    if event.keyCode == 53 && session.ocrSelecting {
      cancelSelection()
      return true
    }
    if event.keyCode == 53 && flags.isSuperset(of: [.control, .option, .command]) {
      session.onAgentInterruption?()
      session.releaseCapture()
      return true
    }
    if event.keyCode == 3 && flags == [.control, .command] {
      session.releaseCapture()
      window?.toggleFullScreen(nil)
      return true
    }
    if [UInt16(12), 13, 43].contains(event.keyCode) && flags == .command {
      session.releaseCapture()
      return false
    }
    return false
  }

  // Resolve the next key through the input state machine and keep local paste separate from physical keys.
  public override func keyDown(with event: NSEvent) {
    if localCommand(event) { return }
    guard canSend, session.profile.keyboardEnabled, let code = PhysicalKey.codes[event.keyCode]
    else { return }
    let flags = modifiers(event)
    let composing =
      hasMarkedText() && session.input.nativeLayout && session.input.mappedTextSupported
      && flags.intersection([.control, .command]).isEmpty
    if composing && code == "Escape" {
      cancelComposition()
      return
    }
    if session.input.usesNativeText(code: code, modifiers: flags) || composing {
      session.output?.enqueue(session.input.beginNativeKey(code: code))
      interpretingEvent = event
      if inputContext?.handleEvent(event) != true { interpretKeyEvents([event]) }
      interpretingEvent = nil
      return
    }

    // A shortcut ends preedit without committing it; ordinary physical keys keep their existing behavior.
    cancelComposition()
    forwardKey(event, code: code)
  }

  // AppKit command callbacks reuse physical input handling without recursively interpreting the same event.
  private func forwardKey(_ event: NSEvent, code: String) {
    let result = session.input.keyDown(
      code: code, characters: event.characters, modifiers: modifiers(event),
      isRepeat: event.isARepeat)
    session.output?.enqueue(result.events)
    if result.paste { session.paste() }
  }

  // Consume translated releases and balance only keys whose physical presses were forwarded.
  public override func keyUp(with event: NSEvent) {
    guard canSend, session.profile.keyboardEnabled, let code = PhysicalKey.codes[event.keyCode]
    else { return }
    session.output?.enqueue(session.input.keyUp(code: code))
  }

  // Preserve modifier side identity while deferring text-producing modifiers until a key arrives.
  public override func flagsChanged(with event: NSEvent) {
    guard canSend, session.profile.keyboardEnabled else { return }
    if event.keyCode == 57 {
      let enabled = event.modifierFlags.contains(.capsLock)
      if enabled != capsLock {
        capsLock = enabled
        session.output?.enqueue([.key("CapsLock", true), .key("CapsLock", false)])
      }
    } else {
      session.output?.enqueue(session.input.modifiersChanged(modifiers(event)))
    }
  }

  // Extract the four shortcut modifiers independently of Caps Lock and native character resolution.
  private func modifiers(_ event: NSEvent) -> KeyModifiers {
    // AppKit retains device-side bits alongside aggregate flags; use the SDK masks rather than a layout table.
    let sides: [(Int32, String)] = [
      (NX_DEVICELCTLKEYMASK, "ControlLeft"), (NX_DEVICERCTLKEYMASK, "ControlRight"),
      (NX_DEVICELSHIFTKEYMASK, "ShiftLeft"), (NX_DEVICERSHIFTKEYMASK, "ShiftRight"),
      (NX_DEVICELCMDKEYMASK, "MetaLeft"), (NX_DEVICERCMDKEYMASK, "MetaRight"),
      (NX_DEVICELALTKEYMASK, "AltLeft"), (NX_DEVICERALTKEYMASK, "AltRight"),
    ]
    session.input.modifierSides = Set(
      sides.filter { event.modifierFlags.rawValue & UInt($0.0) != 0 }.map(\.1))
    var result: KeyModifiers = []
    if event.modifierFlags.contains(.shift) { result.insert(.shift) }
    if event.modifierFlags.contains(.option) { result.insert(.option) }
    if event.modifierFlags.contains(.control) { result.insert(.control) }
    if event.modifierFlags.contains(.command) { result.insert(.command) }
    return result
  }
}

// Preserve SwiftUI's window delegate while asking AppKit to overlay and auto-hide native fullscreen chrome.
@MainActor final class FullscreenWindowDelegate: NSObject, NSWindowDelegate {
  private weak var original: NSWindowDelegate?
  init(original: NSWindowDelegate?) {
    self.original = original
    super.init()
  }

  // Preserve SwiftUI’s original window delegate capabilities alongside fullscreen customization.
  public override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || original?.responds(to: selector) == true
  }

  // Forward window lifecycle methods that the fullscreen adapter does not implement.
  public override func forwardingTarget(for selector: Selector!) -> Any? {
    original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
  }

  // Request native fullscreen chrome that overlays the remote image and hides when idle.
  func window(
    _ window: NSWindow,
    willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
  ) -> NSApplication.PresentationOptions {
    proposedOptions.union([.autoHideToolbar, .autoHideMenuBar, .autoHideDock])
  }
}

// Keep the local click marker accessible to UI tests and passive to mouse input above the Metal view.
@MainActor private final class ClickPreviewView: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    let ring = CAShapeLayer()
    ring.path = CGPath(ellipseIn: CGRect(x: 5, y: 5, width: 34, height: 34), transform: nil)
    ring.strokeColor = NSColor.systemPurple.cgColor
    ring.fillColor = NSColor.systemPurple.withAlphaComponent(0.18).cgColor
    ring.lineWidth = 3
    ring.shadowColor = NSColor.systemPurple.cgColor
    ring.shadowOpacity = 0.6
    ring.shadowRadius = 5
    ring.shadowOffset = .zero
    ring.zPosition = 2
    ring.actions = ["position": NSNull(), "bounds": NSNull()]
    layer = ring
    isHidden = true
    setAccessibilityElement(true)
    setAccessibilityRole(.image)
    setAccessibilityLabel("Proposed agent click")
    setAccessibilityIdentifier("agent-click-preview")
  }

  // This overlay is constructed only by the remote display and never participates in hit testing.
  convenience init() { self.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44)) }
  required init?(coder: NSCoder) { fatalError("ClickPreviewView is constructed programmatically") }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  // Animate in Core Animation so pulsing stays smooth without publishing state on every video frame.
  func show(at point: CGPoint?) {
    guard let point else {
      isHidden = true
      layer?.removeAnimation(forKey: "pulse")
      return
    }
    setFrameOrigin(CGPoint(x: point.x - 22, y: point.y - 22))
    isHidden = false
    guard layer?.animation(forKey: "pulse") == nil else { return }
    let pulse = CABasicAnimation(keyPath: "opacity")
    pulse.fromValue = 0.4
    pulse.toValue = 1
    pulse.duration = 0.55
    pulse.autoreverses = true
    pulse.repeatCount = .infinity
    layer?.add(pulse, forKey: "pulse")
  }
}

// Implement AppKit's text-input contract on the actual first responder, preserving system keyboard-layout behavior.
extension RemoteSurface {
  // Cancel both AppKit's pending dead key and the local preedit when focus, capture, or mode changes.
  private func cancelComposition() {
    inputContext?.discardMarkedText()
    unmarkText()
  }

  // Only committed text reaches the device; preedit updates never enqueue HID events.
  public func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
    unmarkText()
    guard canSend, session.profile.keyboardEnabled else { return }
    session.output?.enqueue(session.input.commitText(text))
  }

  // Store AppKit's UTF-16 selection and show a small local composition preview near the display's lower edge.
  public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard canSend, session.profile.keyboardEnabled, session.input.nativeLayout,
      session.input.mappedTextSupported
    else {
      cancelComposition()
      return
    }
    markedInput =
      (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
    markedSelection = selectedRange
    compositionLabel.stringValue = markedInput.string
    compositionLabel.sizeToFit()
    compositionLabel.setFrameOrigin(
      NSPoint(x: 12, y: max(12, bounds.height - compositionLabel.frame.height - 12)))
    compositionLabel.isHidden = markedInput.length == 0
  }

  // Clear local preedit without sending or replaying any pending text.
  public func unmarkText() {
    markedInput = NSAttributedString(string: "")
    markedSelection = NSRange(location: 0, length: 0)
    compositionLabel.isHidden = true
  }

  // Report local composition ranges only: remote document contents and caret positions are not accessible.
  public func hasMarkedText() -> Bool { markedInput.length > 0 }
  public func markedRange() -> NSRange {
    NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: markedInput.length)
  }
  public func selectedRange() -> NSRange { markedSelection }
  public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard range.location != NSNotFound, range.location <= markedInput.length,
      range.length <= markedInput.length - range.location
    else { return nil }
    actualRange?.pointee = range
    return markedInput.attributedSubstring(from: range)
  }

  // Anchor input-method candidate windows to the local preview rather than guessing the remote caret location.
  public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = markedRange()
    let rect = convert(compositionLabel.frame, to: nil)
    return window?.convertToScreen(rect) ?? .zero
  }
  public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  // Let the input method consume editing keys; unhandled commands still reach the remote physical keyboard.
  public override func doCommand(by selector: Selector) {
    guard let event = interpretingEvent, canSend, let code = PhysicalKey.codes[event.keyCode] else {
      return
    }
    forwardKey(event, code: code)
  }
}
