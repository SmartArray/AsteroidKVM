// Adapt one authenticated KVM session to the agent's narrow pixel-and-input capability boundary.
import CometAgent
import CometCore
import CometMedia
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@MainActor public final class SessionAgentComputer: AgentComputer {
  private weak var session: SessionController?
  private var lease: UUID?
  private var screenSize: CGSize?
  private var sourceSize: CGSize?
  private var lastActionFrame: UUID?
  public var identity: String { session?.profile.agentIdentity ?? "disconnected" }
  private var leasedIdentity: String?
  public var available: Bool {
    session?.phase == .connected && session?.mailbox.snapshot() != nil
      && (session?.mailbox.frameAge ?? .infinity) < 3
  }

  // Hold a weak session reference so closing the connection releases both media and the agent adapter.
  public init(session: SessionController) { self.session = session }

  // Require a live absolute-pointer session and exclusive ownership before any observation or action.
  public func acquire() throws {
    // Report the failed prerequisite precisely; a connected display can still be waiting on video or paste.
    guard let session else {
      throw AgentError(
        "This agent's connection was closed. Open Agent from the current remote display.")
    }
    guard session.phase == .connected else {
      throw AgentError(
        "The remote display is \(session.phase.rawValue). Connect it before starting the agent.")
    }
    guard session.mailbox.snapshot() != nil else {
      throw AgentError(
        "Connected, but no video frame has arrived yet. Wait for the remote picture and retry.")
    }
    guard session.mailbox.frameAge < 3 else {
      throw AgentError(
        "Connected, but the last video frame is over 3 seconds old. Wait for live video and retry.")
    }
    guard !session.pasting else {
      throw AgentError(
        "Clipboard text is still being typed on the remote computer. Wait for paste to finish and retry."
      )
    }
    guard session.profile.keyboardEnabled, session.profile.mouseEnabled,
      session.state.system["absolute_mouse"].bool != false
    else {
      throw AgentError("Enable keyboard, mouse, and absolute mouse mode before starting the agent.")
    }
    session.releaseCapture()
    lease = UUID()
    leasedIdentity = identity
    screenSize = nil
    lastActionFrame = nil
    session.agentOwnsInput = true
  }

  // Invalidating the lease stops the next character or transition even if Codex interruption is delayed.
  public func release() {
    lease = nil
    leasedIdentity = nil
    screenSize = nil
    session?.agentOwnsInput = false
    session?.output?.releaseAll()
  }

  // Copy and compress only requested snapshots off the main actor, leaving the live Metal path untouched.
  public func screen() async throws -> AgentScreen {
    let ticket = try checkedLease()
    guard let session else { throw CancellationError() }
    let deadline = Date().addingTimeInterval(3)
    while let old = lastActionFrame, session.mailbox.snapshot()?.id == old, Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
      try check(ticket)
    }
    guard let frame = session.mailbox.snapshot(), frame.id != lastActionFrame else {
      throw AgentError("The remote video has not advanced. Wait for live video before continuing.")
    }
    let result = try await Task.detached(priority: .userInitiated) {
      let source = CIImage(cvPixelBuffer: frame.buffer)
      let scale = min(1, 1600 / max(source.extent.width, source.extent.height))
      let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      let context = CIContext(options: [.cacheIntermediates: false])
      guard let cg = context.createCGImage(image, from: image.extent.integral) else {
        throw AgentError("Could not capture the remote screen.")
      }
      let data = NSMutableData()
      guard
        let destination = CGImageDestinationCreateWithData(
          data, UTType.jpeg.identifier as CFString, 1, nil)
      else {
        throw AgentError("Could not encode the remote screen.")
      }
      CGImageDestinationAddImage(
        destination, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw AgentError("Could not finish the remote screenshot.")
      }
      return AgentScreen(
        imageURL: "data:image/jpeg;base64," + (data as Data).base64EncodedString(),
        width: cg.width, height: cg.height, id: UUID().uuidString)
    }.value
    try check(ticket)
    screenSize = CGSize(width: result.width, height: result.height)
    sourceSize = frame.size
    lastActionFrame = nil
    return result
  }

  // Every transition is balanced and awaited; text uses individual characters so Pause bounds residual typing.
  public func perform(_ action: AgentAction) async throws {
    let ticket = try checkedLease()
    guard let session, let output = session.output, let size = screenSize,
      session.mailbox.snapshot()?.size == sourceSize
    else { throw AgentError("Remote geometry changed. Read the screen again.") }
    lastActionFrame = session.mailbox.snapshot()?.id
    switch action {
    case .click(let x, let y, let button, let count):
      let hx = ((Double(x) / max(1, size.width - 1)) * 65535 - 32768).rounded()
      let hy = ((Double(y) / max(1, size.height - 1)) * 65535 - 32768).rounded()
      try await send(
        [HIDEvent("mouse_move", ["to": .object(["x": .number(hx), "y": .number(hy)])])], ticket)
      for _ in 0..<count {
        try await send([.button(button, true)], ticket)
        try await Task.sleep(for: .milliseconds(70))
        try await send([.button(button, false)], ticket)
        try await Task.sleep(for: .milliseconds(70))
      }
    case .key(let keys):
      try await send(keys.map { .key($0, true) }, ticket)
      try await Task.sleep(for: .milliseconds(100))
      try await send(keys.reversed().map { .key($0, false) }, ticket)
    case .type(let text):
      for scalar in text.unicodeScalars {
        try check(ticket)
        if scalar == "\n" || scalar == "\t" {
          let code = scalar == "\n" ? "Enter" : "Tab"
          try await send([.key(code, true)], ticket)
          try await Task.sleep(for: .milliseconds(60))
          try await send([.key(code, false)], ticket)
        } else if session.state.mappedText {
          try await send(
            [
              HIDEvent(
                "mapped_text",
                ["text": .string(String(scalar)), "keymap": .string(session.profile.keymap)])
            ], ticket)
        } else {
          guard let api = session.api else { throw CancellationError() }
          try await api.paste(String(scalar), keymap: session.profile.keymap)
          try check(ticket)
        }
      }
    case .scroll(let delta):
      try await send(
        [
          HIDEvent(
            "mouse_wheel",
            [
              "delta": .object(["x": .number(0), "y": .number(Double(-delta))]),
              "squash": .bool(false),
            ])
        ], ticket)
    case .wait(let milliseconds): try await Task.sleep(for: .milliseconds(milliseconds))
    }
    try check(ticket)
    await output.flush()
    lastActionFrame = session.mailbox.snapshot()?.id
    try await Task.sleep(for: .milliseconds(350))
    try check(ticket)
  }

  // Recheck the lease after every await because a pause, disconnect, or manual capture may have intervened.
  private func checkedLease() throws -> UUID {
    try Task.checkCancellation()
    guard let lease, leasedIdentity == identity, available, session?.agentOwnsInput == true else {
      throw AgentError("Remote control is paused or disconnected.")
    }
    return lease
  }
  private func check(_ ticket: UUID) throws {
    guard try checkedLease() == ticket else { throw CancellationError() }
  }
  private func send(_ events: [HIDEvent], _ ticket: UUID) async throws {
    try check(ticket)
    guard let output = session?.output else { throw CancellationError() }
    output.enqueue(events)
    await output.flush()
    try check(ticket)
  }
}
