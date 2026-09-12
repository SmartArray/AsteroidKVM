// Adapt AppKit events to the ordered input engine and retain a stable native Metal surface.
import AppKit
import CometCore
import CometMedia
import IOKit.hidsystem
import MetalKit

@MainActor public final class RemoteSurface: NSView {
  private let session: SessionController
  private var metalView: MTKView?
  private var renderer: MetalVideoRenderer?
  private let selectionLayer = CAShapeLayer()
  private var geometry: DisplayGeometry?
  private var frozen: VideoFrame?
  private var selectionStart: CGPoint?
  private var selectionGeometry: DisplayGeometry?
  private var observers: [NSObjectProtocol] = []
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
    setAccessibilityIdentifier("remote-display")
    setAccessibilityLabel("Remote display")
    setAccessibilityRole(.group)
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
      selectionLayer.strokeColor = NSColor.white.cgColor
      selectionLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
      selectionLayer.lineWidth = 1.5
      layer?.addSublayer(selectionLayer)
    } catch { session.message = error.localizedDescription }
  }
  public required init?(coder: NSCoder) {
    fatalError("RemoteSurface is constructed programmatically")
  }

  // Resize the existing Metal surface to the AppKit bounds without changing media ownership.
  public override func layout() {
    super.layout()
    metalView?.frame = bounds
    if selectionStart != nil { cancelSelection() }
  }

  // Install window-scoped lifecycle observers and native fullscreen behavior.
  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
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

  // Suspend capture when the pointer leaves video, while allowing an OCR drag to finish at its edge.
  public override func mouseExited(with event: NSEvent) {
    if selectionStart == nil { session.releaseCapture() }
  }

  // Remove observers and selection resources when the surface is no longer presented.
  public func teardown() {
    cancelSelection()
    session.releaseCapture()
    metalView?.isPaused = true
    metalView?.delegate = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
  }

  // A frozen frame and fixed geometry make OCR selection deterministic while the stream continues receiving.
  public func synchronize() {
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
    let result = session.input.keyDown(
      code: code, characters: event.characters, modifiers: modifiers(event),
      isRepeat: event.isARepeat)
    session.output?.enqueue(result.events)
    if result.paste { session.paste() }
    if result.compositionUnsupported {
      session.message =
        "Dead keys and IME composition are not supported in Native Keyboard Layout. Use Paste for composed text."
    }
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
