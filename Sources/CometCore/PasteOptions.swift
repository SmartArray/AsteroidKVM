import Foundation

// Only preferences are persisted. Clipboard contents live in a session's temporary preview.
public struct PasteOptions: Codable, Equatable, Sendable {
  public var handleDeadKeys = true
  public var fastMode = false
  public init() {}
}

public struct PastePreview: Identifiable, Equatable, Sendable {
  public let id = UUID()
  public let text: String
  public init(text: String) { self.text = text }
}

public enum PastePreparation {
  public static let limit = 16_384

  // Standard layout names are exact: never apply German rules to an unknown/custom layout.
  // These are spacing accents, not composed letters (é, ä, etc.). The target consumes the
  // extra Space to finish a dead key; existing spaces in the clipboard must remain intact.
  // Reference: https://cgit.freedesktop.org/xkeyboard-config/tree/symbols/de
  public static func deadKeys(for keymap: String) -> Set<Character>? {
    switch keymap.lowercased() {
    case "de": return Set("`´^")
    case "en-us": return []
    default: return nil
    }
  }

  public static func prepare(_ text: String, keymap: String, options: PasteOptions) throws -> String {
    guard text.unicodeScalars.count <= limit else { throw CometError.pasteTooLong }
    guard options.handleDeadKeys else { return text }
    guard let deadKeys = deadKeys(for: keymap) else {
      throw CometError.unsupported("Dead-key handling is not available for this target layout. Turn it off to submit unchanged text.")
    }
    var result = ""
    for character in text {
      result.append(character)
      if deadKeys.contains(character) { result.append(" ") }
    }
    guard result.unicodeScalars.count <= limit else { throw CometError.pasteTooLong }
    return result
  }
}
