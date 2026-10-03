import CometCore
import CometMedia
import CometSessionCore
import MetalKit
import SwiftUI
import UIKit

struct MobileRemoteSurface: UIViewRepresentable {
  @ObservedObject var session: SessionCore
  var blocked: Bool
  var fitToken: Int
  var keyboardVisible = false
  @AppStorage("keyboardToolbarEnabled") private var keyboardToolbarEnabled = true
  func makeUIView(context: Context) -> RemoteTouchView { RemoteTouchView(session: session) }
  func updateUIView(_ view: RemoteTouchView, context: Context) {
    view.synchronize(blocked: blocked, fitToken: fitToken, keyboardVisible: keyboardVisible,
      toolbarEnabled: keyboardToolbarEnabled)
  }
  static func dismantleUIView(_ view: RemoteTouchView, coordinator: ()) {
    view.cancelInteraction()
    view.dismissKeyboard()
    view.renderer?.frozenFrame = nil
  }
}

/// One owner per touch sequence. Dropping fingers never resumes an earlier remote gesture.
final class RemoteTouchView: UIView {
  let session: SessionCore
  let metal = MTKView()
  var renderer: MetalVideoRenderer?
  private var geometry = DisplayGeometry(source: .zero, viewport: .zero)
  private var viewport = ViewportTransform()
  private var blocked = true
  private var fitToken = 0
  private var ownership = TouchOwnership()
  private var owner: Int { ownership.owner.rawValue }
  private var start = CGPoint.zero, last = CGPoint.zero
  private var distance: CGFloat = 0
  private var moved = false, dragging = false, rightClicked = false, secondTap = false
  private var hold: Task<Void, Never>?
  private var relative = MotionAccumulator(), wheel = MotionAccumulator()
  private var snapshot: VideoFrame?
  private let selection = CAShapeLayer()
  private var lastBounds = CGSize.zero
  private var lastRotation = 0
  private var hoverPoint: CGPoint?
  private var modifierSides: Set<String> = []
  private var keyboardRequested = false
  private let keyboardInput = RemoteKeyboardInputView()
  override var canBecomeFirstResponder: Bool { !blocked && !session.ocrSelecting }
  override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
  override var accessibilityValue: String? {
    get {
      let value = "Zoom \(Int(viewport.zoom * 100)) percent"
      #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["ASTEROID_UI_FIXTURE"] == "1" {
          let center = geometry.sourcePoint(viewport.inverse(
            CGPoint(x: geometry.viewport.width / 2, y: geometry.viewport.height / 2),
            in: geometry.viewport))
          return "\(value); center=\(String(format: "%.4f,%.4f", center.x, center.y)); \(UITestInputRecorder.summary) phase=\(session.phase.rawValue) frame=\(session.mailbox.snapshot() != nil)"
        }
      #endif
      return value
    }
    set {}
  }
  private var canSend: Bool {
    !blocked && session.active && !session.pasting && !session.ocrSelecting && !session.ocrBusy
      && snapshot == nil
  }
  init(session: SessionCore) {
    self.session = session
    super.init(frame: .zero)
    isMultipleTouchEnabled = true
    backgroundColor = .black
    metal.isUserInteractionEnabled = false
    metal.device = MTLCreateSystemDefaultDevice()
    metal.clearColor = MTLClearColorMake(0, 0, 0, 1)
    metal.framebufferOnly = true
    metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(metal)
    // A native text responder supplies the system keyboard and owns local IME composition.
    keyboardInput.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    addSubview(keyboardInput)
    keyboardInput.onText = { [weak self] text, modifiers in
      guard let self, self.canSend, self.session.profile.keyboardEnabled else { return }
      if modifiers.isEmpty {
        self.session.output?.keyboardText(text, keymap: self.session.profile.keymap)
      } else {
        let chords = text.map { MobileKeyCodes.shortcutKeys(for: $0) }
        guard chords.allSatisfy({ $0 != nil }) else {
          self.session.message = "This character cannot be combined with shortcut modifiers. Deselect the modifiers to type it normally."
          return
        }
        for chord in chords.compactMap({ $0 }) {
          self.session.output?.keyboardChord(modifiers + chord)
        }
      }
    }
    keyboardInput.onKey = { [weak self] code, modifiers in
      guard let self, self.canSend, self.session.profile.keyboardEnabled else { return }
      self.session.output?.keyboardChord(modifiers + [code])
    }
    if let device = metal.device {
      do {
        let renderer = try MetalVideoRenderer(mailbox: session.mailbox, device: device)
        self.renderer = renderer
        metal.delegate = renderer
        renderer.onGeometry = { [weak self] updated in
          guard let self else { return }
          self.viewport.resize(from: self.geometry, to: updated)
          self.geometry = updated
          self.renderer?.viewportTransform = self.viewport
        }
        renderer.onError = { [weak session] in session?.message = $0 }
      } catch { session.message = error.localizedDescription }
    }
    selection.strokeColor = UIColor.systemTeal.cgColor
    selection.fillColor = UIColor.systemTeal.withAlphaComponent(0.15).cgColor
    selection.lineWidth = 2
    layer.addSublayer(selection)
    isAccessibilityElement = true
    accessibilityLabel = "Remote computer"
    accessibilityHint =
      "Use the controls menu for keys and typing. Scroll actions scroll the remote computer."
    accessibilityTraits = [.allowsDirectInteraction]
    let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
    addGestureRecognizer(hover)
    let scroll = UIPanGestureRecognizer(target: self, action: #selector(pointerScroll(_:)))
    scroll.allowedScrollTypesMask = .all
    scroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    addGestureRecognizer(scroll)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func layoutSubviews() {
    super.layoutSubviews()
    metal.frame = bounds
    if bounds.size != lastBounds {
      cancelInteraction()
      if snapshot != nil {
        session.cancelOCR()
        snapshot = nil
        renderer?.frozenFrame = nil
        session.ocrText = nil
      }
      lastBounds = bounds.size
    }
  }
  func synchronize(blocked: Bool, fitToken: Int, keyboardVisible: Bool, toolbarEnabled: Bool) {
    keyboardInput.setToolbarEnabled(toolbarEnabled)
    keyboardRequested = keyboardVisible && session.profile.keyboardEnabled
    let unavailable = blocked || !session.active || session.pasting
    if unavailable != self.blocked {
      // Input was released when the sheet opened. Re-enabling the surface must not
      // discard a special key or shortcut accepted by that sheet.
      cancelInteraction(releaseRemoteInput: unavailable)
      self.blocked = unavailable
    }
    if self.fitToken != fitToken || lastRotation != session.profile.rotation {
      cancelInteraction()
      self.fitToken = fitToken
      viewport = ViewportTransform()
      renderer?.viewportTransform = viewport
      lastRotation = session.profile.rotation
      if snapshot != nil {
        session.cancelOCR()
        session.ocrText = nil
        snapshot = nil
      }
    }
    renderer?.rotation = session.profile.rotation
    if session.ocrSelecting, snapshot == nil {
      cancelInteraction()
      snapshot = session.mailbox.snapshot()
      renderer?.frozenFrame = snapshot
    }
    if !session.ocrSelecting && !session.ocrBusy && session.ocrText == nil {
      snapshot = nil
      renderer?.frozenFrame = nil
      selection.path = nil
    }
    if !unavailable && !session.ocrSelecting && window != nil {
      if keyboardRequested {
        // SwiftUI may still be updating the dismissed sheet's responder chain.
        // Request focus after that update, and recheck ownership before taking it.
        DispatchQueue.main.async { [weak self] in
          guard let self, self.keyboardRequested, self.canSend, self.window != nil else { return }
          if !self.keyboardInput.isFirstResponder { self.keyboardInput.becomeFirstResponder() }
        }
      } else {
        dismissKeyboard()
        becomeFirstResponder()
      }
    } else {
      dismissKeyboard()
      resignFirstResponder()
    }
  }
  func dismissKeyboard() {
    keyboardInput.clearModifiers()
    keyboardInput.resignFirstResponder()
    keyboardInput.text = ""
  }
  func cancelInteraction(releaseRemoteInput: Bool = true) {
    hold?.cancel()
    hold = nil
    if dragging { session.output?.enqueue([.button("left", false)]) }
    dragging = false
    ownership.cancel()
    moved = false
    rightClicked = false
    relative = MotionAccumulator()
    wheel = MotionAccumulator()
    selection.path = nil
    modifierSides.removeAll()
    hoverPoint = nil
    if releaseRemoteInput {
      _ = session.input.releaseAll()
      session.output?.releasePhysicalInput()
    }
  }
  private func activeTouches(_ event: UIEvent?) -> [UITouch] {
    (event?.allTouches ?? []).filter {
      $0.view === self && $0.phase != .ended && $0.phase != .cancelled
    }.sorted { ObjectIdentifier($0).hashValue < ObjectIdentifier($1).hashValue }
  }
  private func centroid(_ touches: [UITouch]) -> CGPoint {
    guard !touches.isEmpty else { return last }
    return CGPoint(
      x: touches.map { $0.location(in: self).x }.reduce(0, +) / CGFloat(touches.count),
      y: touches.map { $0.location(in: self).y }.reduce(0, +) / CGFloat(touches.count))
  }
  private func span(_ touches: [UITouch]) -> CGFloat {
    guard touches.count == 2 else { return 0 }
    let a = touches[0].location(in: self)
    let b = touches[1].location(in: self)
    return hypot(a.x - b.x, a.y - b.y)
  }
  private func inside(_ p: CGPoint) -> Bool {
    geometry.valid && geometry.imageRect.contains(viewport.inverse(p, in: geometry.viewport))
  }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    let all = activeTouches(event)
    let count = all.count
    let point = centroid(all)
    if count > 1 {
      hold?.cancel()
      hold = nil
      if dragging {
        session.output?.enqueue([.button("left", false)])
        dragging = false
      }
      ownership.begin(
        count: count, permitted: !blocked && session.active && !session.pasting,
        selecting: session.ocrSelecting, inside: inside(point))
      guard owner == 2 || owner == 3 else { return }
      last = point
      distance = span(all)
      moved = true
      return
    }
    ownership.begin(
      count: count, permitted: !blocked && session.active && !session.pasting,
      selecting: session.ocrSelecting, inside: inside(point))
    guard owner != -1, let touch = touches.first else { return }
    if owner == 4 {
      start = point
      last = point
      return
    }
    guard canSend, session.profile.mouseEnabled else {
      ownership.end(remaining: count)
      return
    }
    if !keyboardRequested { becomeFirstResponder() }
    start = point
    last = point
    moved = false
    rightClicked = false
    secondTap = touch.tapCount >= 2
    if touch.type == .indirectPointer && event?.buttonMask.contains(.secondary) == true {
      position(point)
      click("right")
      rightClicked = true
      return
    }
    hold = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(self?.secondTap == true ? 220 : 500)) } catch {
        return
      }
      guard let self, self.owner == 1, !self.moved, self.canSend else { return }
      self.position(self.last)
      if self.secondTap {
        self.dragging = true
        self.session.output?.enqueue([.button("left", true)])
      } else {
        self.click("right")
        self.rightClicked = true
      }
    }
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    let all = activeTouches(event)
    let point = centroid(all)
    let delta = CGPoint(x: point.x - last.x, y: point.y - last.y)
    defer { last = point }
    switch owner {
    case 1:
      guard canSend, all.count == 1, !rightClicked else { return }
      if hypot(point.x - start.x, point.y - start.y) > 5 {
        moved = true
        hold?.cancel()
      }
      if secondTap && moved && !dragging {
        position(last)
        dragging = true
        session.output?.enqueue([.button("left", true)])
      }
      if session.profile.mobileMouseMode == .absolute {
        position(point)
      } else {
        sendDelta(
          "mouse_relative",
          packets: relative.consume(
            dx: delta.x * session.profile.mouseSensitivity,
            dy: delta.y * session.profile.mouseSensitivity))
      }
    case 2:
      guard all.count == 2 else { return }
      let currentSpan = span(all)
      viewport.move(delta, geometry: geometry)
      if distance > 0 {
        viewport.scale(by: currentSpan / distance, anchor: point, geometry: geometry)
      }
      distance = currentSpan
      renderer?.viewportTransform = viewport
    case 3:
      guard canSend, all.count == 3, session.profile.mouseEnabled else { return }
      scroll(delta.y)
    case 4:
      guard all.count == 1 else { return }
      selection.path =
        UIBezierPath(
          rect: CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x),
            height: abs(point.y - start.y))
        ).cgPath
    default: break
    }
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    hold?.cancel()
    hold = nil
    let point = touches.first?.location(in: self) ?? last
    if owner == 1 && canSend {
      if dragging {
        session.output?.enqueue([.button("left", false)])
        dragging = false
      } else if !moved && !rightClicked {
        position(point)
        click("left")
      }
    } else if owner == 4, let snapshot {
      let a = viewport.inverse(start, in: geometry.viewport)
      let b = viewport.inverse(point, in: geometry.viewport)
      let crop = geometry.sourceCrop(from: a, to: b)
      if crop.width >= 2 && crop.height >= 2 { session.recognize(frame: snapshot, crop: crop) }
      selection.path = nil
    }
    ownership.end(remaining: activeTouches(event).count)
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    let selecting = session.ocrSelecting
    cancelInteraction()
    if selecting { session.cancelOCR() }
    ownership.end(remaining: activeTouches(event).count)
  }
  private func position(_ point: CGPoint) {
    guard canSend, session.profile.mouseEnabled, geometry.valid,
      session.profile.mobileMouseMode == .absolute
    else { return }
    let (x, y) = geometry.hidPoint(viewport.inverse(point, in: geometry.viewport))
    session.output?.enqueue([
      HIDEvent("mouse_move", ["to": .object(["x": .number(Double(x)), "y": .number(Double(y))])])
    ])
  }
  private func click(_ button: String) {
    session.output?.enqueue([.button(button, true), .button(button, false)])
  }
  private func sendDelta(_ type: String, packets: [(Int, Int)]) {
    guard canSend else { return }
    session.output?.enqueue(
      packets.map { x, y in
        HIDEvent(
          type,
          [
            "delta": .object(["x": .number(Double(x)), "y": .number(Double(y))]),
            "squash": .bool(false),
          ])
      })
  }
  private func scroll(_ dy: CGFloat) {
    sendDelta(
      "mouse_wheel",
      packets: wheel.consume(
        dx: 0,
        dy: dy / 12 * session.profile.scrollSensitivity
          * (session.profile.reverseScrolling ? 1 : -1)))
  }
  override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
    guard canSend, session.profile.mouseEnabled else { return false }
    if direction == .up {
      scroll(-72)
    } else if direction == .down {
      scroll(72)
    } else {
      return false
    }
    UIAccessibility.post(notification: .pageScrolled, argument: "Remote screen scrolled")
    return true
  }
  @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
    let point = gesture.location(in: self)
    defer { hoverPoint = gesture.state == .ended || gesture.state == .cancelled ? nil : point }
    guard gesture.state == .changed, inside(point), canSend, session.profile.mouseEnabled else {
      return
    }
    if session.profile.mobileMouseMode == .absolute {
      position(point)
    } else if let previous = hoverPoint {
      sendDelta(
        "mouse_relative",
        packets: relative.consume(
          dx: (point.x - previous.x) * session.profile.mouseSensitivity,
          dy: (point.y - previous.y) * session.profile.mouseSensitivity))
    }
  }
  @objc private func pointerScroll(_ gesture: UIPanGestureRecognizer) {
    guard canSend else { return }
    scroll(gesture.translation(in: self).y)
    gesture.setTranslation(.zero, in: self)
  }
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard canSend, session.profile.keyboardEnabled else {
      super.pressesBegan(presses, with: event)
      return
    }
    for press in presses {
      guard let key = press.key else { continue }
      if let (_, side) = MobileKeyCodes.modifier(Int(key.keyCode.rawValue)) {
        modifierSides.insert(side)
        session.input.modifierSides = modifierSides
        continue
      }
      guard let code = MobileKeyCodes.code(Int(key.keyCode.rawValue)) else { continue }
      var flags: KeyModifiers = []
      if key.modifierFlags.contains(.shift) { flags.insert(.shift) }
      if key.modifierFlags.contains(.alternate) { flags.insert(.option) }
      if key.modifierFlags.contains(.control) { flags.insert(.control) }
      if key.modifierFlags.contains(.command) { flags.insert(.command) }
      // Clipboard access stays in the native Type editor. Command-V here is a remote shortcut.
      session.input.pasteEnabled = false
      let result = session.input.keyDown(code: code, characters: key.characters, modifiers: flags)
      session.output?.enqueue(result.events)
    }
  }
  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    for press in presses {
      guard let key = press.key else { continue }
      var modifiers: KeyModifiers = []
      let flags = key.modifierFlags
      if flags.contains(.shift) { modifiers.insert(.shift) }
      if flags.contains(.alternate) { modifiers.insert(.option) }
      if flags.contains(.control) { modifiers.insert(.control) }
      if flags.contains(.command) { modifiers.insert(.command) }
      if let (flag, side) = MobileKeyCodes.modifier(Int(key.keyCode.rawValue)) {
        modifierSides.remove(side)
        session.input.modifierSides = modifierSides
        let family = side.replacingOccurrences(of: "Left", with: "").replacingOccurrences(
          of: "Right", with: "")
        if !modifierSides.contains(where: { $0.hasPrefix(family) }) { modifiers.remove(flag) }
      } else if let code = MobileKeyCodes.code(Int(key.keyCode.rawValue)) {
        session.output?.enqueue(session.input.keyUp(code: code))
      }
      session.output?.enqueue(session.input.modifiersChanged(modifiers))
    }
  }
  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    cancelInteraction()
  }
}

/// A native accessory keeps the keys attached to both docked and floating iPad keyboards.
private final class RemoteKeyboardToolbar: UIView {
  var onKey: ((String) -> Void)?
  private var selected: Set<String> = []
  private var modifierButtons: [String: UIButton] = [:]
  private let modifiers = [("Ctrl", "ControlLeft"), ("Alt", "AltLeft"),
    ("Shift", "ShiftLeft"), ("Win/⌘", "MetaLeft"), ("AltGr", "AltRight")]
  override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 60) }

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 60))
    autoresizingMask = [.flexibleWidth]
    let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    background.translatesAutoresizingMaskIntoConstraints = false
    addSubview(background)
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsHorizontalScrollIndicator = true
    scroll.alwaysBounceHorizontal = true
    scroll.accessibilityIdentifier = "keyboard-special-keys"
    addSubview(scroll)
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 6
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      background.leadingAnchor.constraint(equalTo: leadingAnchor),
      background.trailingAnchor.constraint(equalTo: trailingAnchor),
      background.topAnchor.constraint(equalTo: topAnchor),
      background.bottomAnchor.constraint(equalTo: bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -10),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
    ])
    let keys = [("Esc", "Escape"), ("Tab", "Tab"), ("←", "ArrowLeft"), ("↑", "ArrowUp"),
      ("↓", "ArrowDown"), ("→", "ArrowRight")]
      + (1...12).map { ("F\($0)", "F\($0)") }
      + [("Home", "Home"), ("End", "End"), ("PgUp", "PageUp"), ("PgDn", "PageDown"),
        ("Ins", "Insert"), ("Del", "Delete"), ("Caps", "CapsLock"), ("PrtSc", "PrintScreen"),
        ("ScrLk", "ScrollLock"), ("Pause", "Pause"), ("NumLk", "NumLock")]
    for (title, code) in modifiers + keys {
      let isModifier = modifiers.contains { $0.1 == code }
      let button = UIButton(type: .system)
      var config = UIButton.Configuration.filled()
      config.title = title
      config.baseBackgroundColor = .secondarySystemGroupedBackground
      config.baseForegroundColor = .label
      config.cornerStyle = .medium
      config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
      button.configuration = config
      button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
      button.accessibilityIdentifier = "keyboard-key-\(code)"
      button.accessibilityLabel = ["ControlLeft": "Control", "AltLeft": "Alt",
        "ShiftLeft": "Shift", "MetaLeft": "Windows or Command", "AltRight": "AltGr",
        "ArrowLeft": "Left arrow", "ArrowUp": "Up arrow", "ArrowDown": "Down arrow",
        "ArrowRight": "Right arrow", "PageUp": "Page up", "PageDown": "Page down",
        "CapsLock": "Caps Lock", "PrintScreen": "Print Screen", "ScrollLock": "Scroll Lock",
        "NumLock": "Num Lock"][code] ?? code
      if isModifier {
        modifierButtons[code] = button
        button.accessibilityHint = "Select for the next key. Tap again to deselect."
      }
      button.configurationUpdateHandler = { button in
        button.configuration?.baseBackgroundColor = button.isSelected ? .systemIndigo : .secondarySystemGroupedBackground
        button.configuration?.baseForegroundColor = button.isSelected ? .white : .label
      }
      button.addAction(UIAction { [weak self] _ in
        guard let self else { return }
        if isModifier {
          if !self.selected.insert(code).inserted { self.selected.remove(code) }
          self.updateModifiers()
        } else {
          self.onKey?(code)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
      }, for: .touchUpInside)
      stack.addArrangedSubview(button)
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      button.heightAnchor.constraint(equalToConstant: 44).isActive = true
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  func consumeModifiers() -> [String] {
    let codes = modifiers.map(\.1).filter { selected.contains($0) }
    clearModifiers()
    return codes
  }
  func clearModifiers() {
    selected.removeAll()
    updateModifiers()
  }
  private func updateModifiers() {
    for (code, button) in modifierButtons {
      button.isSelected = selected.contains(code)
      button.accessibilityValue = button.isSelected ? "Selected" : "Not selected"
    }
  }
}

// Only committed text reaches the KVM; composition and prediction remain local to UIKit.
private final class RemoteKeyboardInputView: UITextView, UITextViewDelegate {
  var onText: ((String, [String]) -> Void)?
  var onKey: ((String, [String]) -> Void)?
  private let toolbar = RemoteKeyboardToolbar()
  private var toolbarEnabled = false

  func setToolbarEnabled(_ enabled: Bool) {
    guard enabled != toolbarEnabled else { return }
    toolbarEnabled = enabled
    clearModifiers()
    inputAccessoryView = enabled ? toolbar : nil
    if isFirstResponder { reloadInputViews() }
  }
  func clearModifiers() { toolbar.clearModifiers() }
  private func sendKey(_ code: String) { onKey?(code, toolbar.consumeModifiers()) }
  override var hasText: Bool { true }  // Backspace must work on the remote document even with no local text.
  init() {
    super.init(frame: .zero, textContainer: nil)
    delegate = self
    toolbar.onKey = { [weak self] code in self?.sendKey(code) }
    backgroundColor = .clear
    textColor = .clear
    tintColor = .clear
    isScrollEnabled = false
    isAccessibilityElement = false
    autocorrectionType = .no
    autocapitalizationType = .none
    smartQuotesType = .no
    smartDashesType = .no
    smartInsertDeleteType = .no
    spellCheckingType = .no
    keyboardDismissMode = .none
    inputAssistantItem.leadingBarButtonGroups = []
    inputAssistantItem.trailingBarButtonGroups = []
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  func textViewDidChange(_ textView: UITextView) {
    guard markedTextRange == nil, !text.isEmpty else { return }
    let committed = text ?? ""
    text = ""
    onText?(committed, toolbar.consumeModifiers())
  }
  func textView(
    _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
  ) -> Bool {
    if markedTextRange == nil, text == "\n" {
      sendKey("Enter")
      return false
    }
    return true
  }
  override func deleteBackward() {
    if markedTextRange != nil || !text.isEmpty {
      super.deleteBackward()
    } else {
      sendKey("Backspace")
    }
  }
}

enum MobileKeyCodes {
  // Shortcut chords use the same browser/USB key identities as the Special keys menu.
  static func shortcutKeys(for character: Character) -> [String]? {
    let text = String(character)
    if text.count == 1, let scalar = text.uppercased().unicodeScalars.first,
      text.uppercased().unicodeScalars.count == 1, (65...90).contains(scalar.value) {
      return (text == text.uppercased() ? ["ShiftLeft"] : []) + ["Key" + String(scalar)]
    }
    if let value = character.asciiValue, (48...57).contains(value) { return ["Digit" + text] }
    let keys = [" ": "Space", "\t": "Tab", "\n": "Enter", "-": "Minus", "=": "Equal",
      "[": "BracketLeft", "]": "BracketRight", "\\": "Backslash", ";": "Semicolon",
      "'": "Quote", "`": "Backquote", ",": "Comma", ".": "Period", "/": "Slash"]
    if let code = keys[text] { return [code] }
    let shifted = ["!": "Digit1", "@": "Digit2", "#": "Digit3", "$": "Digit4", "%": "Digit5",
      "^": "Digit6", "&": "Digit7", "*": "Digit8", "(": "Digit9", ")": "Digit0",
      "_": "Minus", "+": "Equal", "{": "BracketLeft", "}": "BracketRight", "|": "Backslash",
      ":": "Semicolon", "\"": "Quote", "~": "Backquote", "<": "Comma", ">": "Period", "?": "Slash"]
    return shifted[text].map { ["ShiftLeft", $0] }
  }
  static func modifier(_ code: Int) -> (KeyModifiers, String)? {
    [
      224: (.control, "ControlLeft"), 225: (.shift, "ShiftLeft"), 226: (.option, "AltLeft"),
      227: (.command, "MetaLeft"), 228: (.control, "ControlRight"), 229: (.shift, "ShiftRight"),
      230: (.option, "AltRight"), 231: (.command, "MetaRight"),
    ][code]
  }
  static func code(_ value: Int) -> String? {
    if (4...29).contains(value) { return "Key" + String(UnicodeScalar(65 + value - 4)!) }
    if (30...38).contains(value) { return "Digit\(value-29)" }
    if (58...69).contains(value) { return "F\(value-57)" }
    return [
      39: "Digit0", 40: "Enter", 41: "Escape", 42: "Backspace", 43: "Tab", 44: "Space", 45: "Minus",
      46: "Equal", 47: "BracketLeft", 48: "BracketRight", 49: "Backslash", 50: "IntlHash",
      51: "Semicolon", 52: "Quote", 53: "Backquote", 54: "Comma", 55: "Period", 56: "Slash",
      57: "CapsLock", 70: "PrintScreen", 71: "ScrollLock", 72: "Pause", 73: "Insert", 74: "Home",
      75: "PageUp", 76: "Delete", 77: "End", 78: "PageDown", 79: "ArrowRight", 80: "ArrowLeft",
      81: "ArrowDown", 82: "ArrowUp", 83: "NumLock", 84: "NumpadDivide", 85: "NumpadMultiply",
      86: "NumpadSubtract", 87: "NumpadAdd", 88: "NumpadEnter", 89: "Numpad1", 90: "Numpad2",
      91: "Numpad3", 92: "Numpad4", 93: "Numpad5", 94: "Numpad6", 95: "Numpad7", 96: "Numpad8",
      97: "Numpad9", 98: "Numpad0", 99: "NumpadDecimal", 100: "IntlBackslash",
    ][value]
  }
}
