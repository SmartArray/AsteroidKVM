// Keep local permission, transcript budgets, and link decisions independent of model instructions and UI rendering.
import Foundation

// Permissions are chosen locally; only full control deliberately permits unreviewed remote input.
public enum AgentControlMode: String, CaseIterable, Sendable {
  case observe = "Observation only"
  case review = "Approve each action"
  case fullControl = "Full control"
}

// Each approval names one immutable action, observation, and target; callers approve only its unique identifier.
public struct AgentApproval: Identifiable, Sendable {
  public let id: UUID
  public let action: AgentAction
  public let screen: AgentScreen
  public let targetIdentity: String
  public var expiresAt: Date { screen.capturedAt.addingTimeInterval(60) }
}

// Budget UTF-8 bytes rather than characters so multi-byte text cannot evade retained-memory limits.
public struct AgentTranscript {
  public static let maximumMessages = 1000
  public static let maximumMessageBytes = 64 * 1024
  public static let maximumTotalBytes = 1024 * 1024
  public private(set) var messages: [AgentMessage] = []
  public private(set) var byteCount = 0

  // Start with an empty transcript; callers cannot supply state that bypasses its accounting limits.
  public init() {}

  // Validate before mutating, including replacement completions and repeated deltas to an existing item.
  public mutating func put(_ message: AgentMessage, delta: Bool = false) throws {
    let index = messages.firstIndex { $0.id == message.id && $0.kind == message.kind }
    let old = index.map { messages[$0] }
    let text = delta ? (old?.text ?? "") + message.text : message.text
    let count = text.utf8.count + message.id.utf8.count
    let previousCount = old.map { $0.text.utf8.count + $0.id.utf8.count } ?? 0
    guard count <= Self.maximumMessageBytes,
      byteCount - previousCount + count <= Self.maximumTotalBytes,
      index != nil || messages.count < Self.maximumMessages
    else { throw AgentError("Chat output exceeded its safety limit. Start a new conversation.") }
    let replacement = AgentMessage(id: message.id, kind: message.kind, text: text)
    if let index { messages[index] = replacement } else { messages.append(replacement) }
    byteCount += count - previousCount
  }

  // Clearing releases the entire bounded store without leaving a stale accounting total.
  public mutating func clear() {
    messages.removeAll()
    byteCount = 0
  }
}

// Native Markdown can contain local or custom URLs; only explicit web destinations may leave the chat.
public enum AgentLinkPolicy {
  public static func allows(_ url: URL) -> Bool {
    ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      && url.host?.isEmpty == false && url.user == nil && url.password == nil
  }
}
