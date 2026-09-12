// Keep runtime model metadata separate from conversation and native presentation state.
import CometCore
import Foundation

public struct AgentModel: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let reasoningEffort: String

  // Use the wire model identifier, excluding hidden and text-only models that cannot inspect the remote screen.
  public init?(_ value: JSONValue) {
    guard let id = value["model"].string, !id.isEmpty, id.utf8.count <= 200,
      value["hidden"].bool != true,
      value["inputModalities"] == .null || value["inputModalities"].array.contains(.string("image"))
    else { return nil }
    self.id = id
    name = String((value["displayName"].string ?? id).prefix(200))
    let efforts = value["supportedReasoningEfforts"].array.compactMap {
      $0["reasoningEffort"].string
    }
    reasoningEffort =
      efforts.isEmpty || efforts.contains("medium")
      ? "medium" : value["defaultReasoningEffort"].string ?? efforts[0]
  }
}
