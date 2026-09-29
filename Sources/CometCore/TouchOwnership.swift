import Foundation

/// Ownership persists until all fingers lift; losing a finger cannot create a new click.
public struct TouchOwnership: Equatable, Sendable {
  public enum Owner: Int, Sendable {
    case suppressed = -1
    case idle = 0
    case mouse = 1
    case viewport = 2
    case scroll = 3
    case selection = 4
  }
  public private(set) var owner: Owner = .idle
  public init() {}
  @discardableResult public mutating func begin(
    count: Int, permitted: Bool, selecting: Bool, inside: Bool
  ) -> Owner {
    if owner == .suppressed { return owner }
    guard permitted, count > 0, count <= 3 else {
      owner = .suppressed
      return owner
    }
    if selecting {
      owner = count == 1 && inside ? .selection : .suppressed
    } else if count == 1 {
      owner = inside ? .mouse : .suppressed
    } else {
      owner = count == 2 ? .viewport : .scroll
    }
    return owner
  }
  public mutating func end(remaining: Int) { owner = remaining == 0 ? .idle : .suppressed }
  public mutating func cancel() { owner = .idle }
}
