// Model input as ordered values so physical keys, mapped text, and paste cannot race.
import Foundation

public struct HIDEvent: Equatable, Sendable {
  public var type: String
  public var payload: JSONValue
  public init(_ type: String, _ values: [String: JSONValue]) {
    self.type = type
    payload = .object(values)
  }
  public var json: JSONValue { .object(["event_type": .string(type), "event": payload]) }

  // Encode a physical key transition using Comet’s browser-style key identity.
  public static func key(_ code: String, _ down: Bool) -> Self {
    .init("key", ["key": .string(code), "state": .bool(down)])
  }

  // Encode a mouse transition separately from keyboard state.
  public static func button(_ button: String, _ down: Bool) -> Self {
    .init("mouse_button", ["button": .string(button), "state": .bool(down)])
  }
}

public struct KeyModifiers: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let shift = Self(rawValue: 1), option = Self(rawValue: 2),
    control = Self(rawValue: 4), command = Self(rawValue: 8)
  public static let physical: [(Self, String)] = [
    (.control, "ControlLeft"), (.command, "MetaLeft"), (.shift, "ShiftLeft"), (.option, "AltLeft"),
  ]
}

public struct InputResult: Sendable {
  public var events: [HIDEvent] = []
  public var paste = false
  public var compositionUnsupported = false
  public init() {}
}

public struct InputEngine: Sendable {
  public var nativeLayout = false
  public var mappedTextSupported = false
  public var pasteEnabled = true
  public var keymap = "en-us"
  public var modifierSides: Set<String>?
  private var sentModifiers: Set<String> = []
  private var held: Set<String> = []
  private var translated: Set<String> = []
  public init() {}

  // Defer modifier presses until a key identifies whether it is text, a remote shortcut, or local paste.
  public mutating func modifiersChanged(_ modifiers: KeyModifiers) -> [HIDEvent] {
    let wanted = desiredModifiers(modifiers)
    let released = sentModifiers.subtracting(wanted).sorted()
    sentModifiers.subtract(released)
    return released.map { .key($0, false) }
  }

  // Preserve left/right modifier identity, including right Option's physical AltGr semantics.
  private func desiredModifiers(_ modifiers: KeyModifiers) -> Set<String> {
    var desired: Set<String> = []
    for (flag, left) in KeyModifiers.physical where modifiers.contains(flag) {
      let right = left.replacingOccurrences(of: "Left", with: "Right")
      let sides = modifierSides?.intersection([left, right]) ?? []
      desired.formUnion(sides.isEmpty ? [left] : sides)
    }
    return desired
  }

  // Flush deferred modifiers immediately before a physical key or mouse button uses them.
  public mutating func flushModifiers(_ modifiers: KeyModifiers) -> [HIDEvent] {
    var events = modifiersChanged(modifiers)
    for code in desiredModifiers(modifiers).subtracting(sentModifiers).sorted() {
      events.append(.key(code, true))
      sentModifiers.insert(code)
    }
    return events
  }

  // macOS supplies characters; this engine never translates Mac characters into target layout keys.
  public mutating func keyDown(
    code: String, characters: String?, modifiers: KeyModifiers, isRepeat: Bool = false
  ) -> InputResult {
    var result = InputResult()
    if pasteEnabled && code == "KeyV" && modifiers == .command {
      result.events = releaseAll()
      translated.insert(code)
      result.paste = !isRepeat
      return result
    }
    let physicalOnly =
      code.hasPrefix("Arrow") || code.hasPrefix("F") && Int(code.dropFirst()) != nil
      || [
        "Escape", "Tab", "Enter", "Backspace", "Delete", "Home", "End", "PageUp", "PageDown",
        "CapsLock",
      ].contains(code)
    if nativeLayout && mappedTextSupported && !physicalOnly
      && modifiers.intersection([.control, .command]).isEmpty
    {
      result.events = releaseSentModifiers()
      translated.insert(code)
      let scalars =
        characters?.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) } ?? []
      if scalars.isEmpty {
        result.compositionUnsupported = true
        return result
      }
      for scalar in scalars {
        result.events.append(
          HIDEvent("mapped_text", ["text": .string(String(scalar)), "keymap": .string(keymap)]))
      }
      return result
    }

    // Ignore host repeat events for physical keys so the remote OS owns the repeat rate.
    if held.contains(code) || isRepeat { return result }
    result.events += flushModifiers(modifiers)
    translated.remove(code)
    held.insert(code)
    result.events.append(.key(code, true))
    return result
  }

  // Consume translated releases and balance only keys whose physical presses were forwarded.
  public mutating func keyUp(code: String) -> [HIDEvent] {
    if translated.remove(code) != nil { return [] }
    guard held.remove(code) != nil else { return [] }
    return [.key(code, false)]
  }

  // Release only modifiers already forwarded to the remote computer.
  private mutating func releaseSentModifiers() -> [HIDEvent] {
    let events = sentModifiers.sorted().reversed().map { HIDEvent.key($0, false) }
    sentModifiers = []
    return events
  }

  // Clear pending and held input so capture and connection transitions cannot replay it.
  public mutating func releaseAll() -> [HIDEvent] {
    let events = held.sorted().map { HIDEvent.key($0, false) } + releaseSentModifiers()
    held.removeAll()
    translated.removeAll()
    modifierSides = nil
    return events
  }
}

// A single main-actor producer and draining task preserve arrival order across transport awaits.
@MainActor public final class HIDOutput {
  public typealias Send = @Sendable (HIDEvent) async throws -> Void
  public typealias Paste = @Sendable (String, String) async throws -> Void
  private enum Command {
    case event(HIDEvent)
    case paste(String, String)
    case barrier(CheckedContinuation<Void, Never>)
  }
  private var pending: [Command] = []
  private var worker: Task<Void, Never>?
  private var pasteRunning = false
  private var keys: Set<String> = []
  private var buttons: Set<String> = []
  private let send: Send
  private let printText: Paste
  public private(set) var pasting = false
  public var onPasteChanged: ((Bool) -> Void)?
  public var onError: ((Error) -> Void)?
  public init(send: @escaping Send, paste: @escaping Paste) {
    self.send = send
    printText = paste
  }

  // Bound the queue and coalesce absolute motion without discarding key transitions.
  public func enqueue(_ events: [HIDEvent]) {
    guard !pasting else { return }
    for event in events {
      if pending.count > 512 {
        releaseAll()
        onError?(
          CometError.unsupported(
            "Input paused because the connection is too slow. Click the display to resume."))
        return
      }
      if event.type == "mouse_move", case .event(let previous) = pending.last,
        previous.type == "mouse_move"
      {
        pending.removeLast()
      }
      track(event)
      pending.append(.event(event))
    }
    drain()
  }

  // Track possibly held remote keys before asynchronous transmission for conservative cleanup.
  private func track(_ event: HIDEvent) {
    if event.type == "key", let key = event.payload["key"].string {
      if event.payload["state"].bool == true { keys.insert(key) } else { keys.remove(key) }
    }
    if event.type == "mouse_button", let button = event.payload["button"].string {
      if event.payload["state"].bool == true {
        buttons.insert(button)
      } else {
        buttons.remove(button)
      }
    }
  }

  // Release is a barrier: stale queued input is discarded and every possibly held input is balanced.
  public func releaseAll() {
    var possibleKeys = keys
    var possibleButtons = buttons
    let hadQueuedPaste = pending.contains {
      if case .paste = $0 { return true }
      return false
    }
    for command in pending {
      if case .event(let event) = command {
        if event.type == "key", let key = event.payload["key"].string { possibleKeys.insert(key) }
        if event.type == "mouse_button", let button = event.payload["button"].string {
          possibleButtons.insert(button)
        }
      }
      if case .barrier(let continuation) = command { continuation.resume() }
    }
    pending.removeAll()
    if hadQueuedPaste && !pasteRunning {
      pasting = false
      onPasteChanged?(false)
    }
    pending += possibleKeys.sorted().map { .event(.key($0, false)) }
    pending += possibleButtons.sorted().map { .event(.button($0, false)) }
    keys.removeAll()
    buttons.removeAll()
    drain()
  }

  // Paste locks out live input synchronously, then waits behind releases in the same FIFO.
  public func paste(_ text: String, keymap: String) {
    guard !pasting else { return }
    releaseAll()
    pasting = true
    onPasteChanged?(true)
    pending.append(.paste(text, keymap))
    drain()
  }

  // Place a FIFO barrier so callers can await prior output without reordering it.
  public func flush() async {
    await withCheckedContinuation { continuation in
      pending.append(.barrier(continuation))
      drain()
    }
  }

  // Cancel owned asynchronous work and release resources without affecting another session.
  public func stop() {
    worker?.cancel()
    worker = nil
    for command in pending {
      if case .barrier(let continuation) = command { continuation.resume() }
    }
    pending.removeAll()
    keys.removeAll()
    buttons.removeAll()
    pasting = false
    onPasteChanged?(false)
  }

  // Serialize HID and paste work in one cancellable consumer.
  private func drain() {
    guard worker == nil else { return }
    worker = Task { [weak self] in
      guard let self else { return }
      while !pending.isEmpty && !Task.isCancelled {
        let command = pending.removeFirst()
        do {
          switch command {
          case .event(let event):
            try await send(event)

            // Firmware acknowledges mapped text before USB reports necessarily settle. Hardware verification
            // showed burst characters losing modifiers; this bounded cadence preserves the daemon's sequences.
            if event.type == "mapped_text" { try await Task.sleep(for: .milliseconds(120)) }
          case .paste(let text, let keymap):
            pasteRunning = true
            defer { pasteRunning = false }
            try await printText(text, keymap)
            pasting = false
            onPasteChanged?(false)
          case .barrier(let continuation): continuation.resume()
          }
        } catch {
          onError?(error)
          for queued in pending {
            if case .barrier(let continuation) = queued { continuation.resume() }
          }
          pending.removeAll()
          keys.removeAll()
          buttons.removeAll()
          pasting = false
          onPasteChanged?(false)
          break
        }
      }
      worker = nil
    }
  }
}

// Physical key codes follow USB/browser semantics; they are not character-layout translations.
public enum PhysicalKey {
  public static let codes: [UInt16: String] = [
    0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH", 5: "KeyG", 6: "KeyZ", 7: "KeyX",
    8: "KeyC", 9: "KeyV", 10: "IntlBackslash", 11: "KeyB",
    12: "KeyQ", 13: "KeyW", 14: "KeyE", 15: "KeyR", 16: "KeyY", 17: "KeyT", 18: "Digit1",
    19: "Digit2", 20: "Digit3", 21: "Digit4", 22: "Digit6", 23: "Digit5",
    24: "Equal", 25: "Digit9", 26: "Digit7", 27: "Minus", 28: "Digit8", 29: "Digit0",
    30: "BracketRight", 31: "KeyO", 32: "KeyU", 33: "BracketLeft", 34: "KeyI", 35: "KeyP",
    36: "Enter", 37: "KeyL", 38: "KeyJ", 39: "Quote", 40: "KeyK", 41: "Semicolon", 42: "Backslash",
    43: "Comma", 44: "Slash", 45: "KeyN", 46: "KeyM", 47: "Period",
    48: "Tab", 49: "Space", 50: "Backquote", 51: "Backspace", 53: "Escape", 57: "CapsLock",
    65: "NumpadDecimal", 67: "NumpadMultiply", 69: "NumpadAdd", 71: "NumLock",
    75: "NumpadDivide", 76: "NumpadEnter", 78: "NumpadSubtract", 81: "NumpadEqual", 82: "Numpad0",
    83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4",
    87: "Numpad5", 88: "Numpad6", 89: "Numpad7", 91: "Numpad8", 92: "Numpad9", 96: "F5", 97: "F6",
    98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
    105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Insert",
    115: "Home", 116: "PageUp", 117: "Delete", 118: "F4", 119: "End", 120: "F2",
    121: "PageDown", 122: "F1", 123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown",
    126: "ArrowUp",
  ]
}
