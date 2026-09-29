import CoreGraphics
import Foundation

/// Local view navigation composed with the existing rotation/pixel-aspect geometry.
public struct ViewportTransform: Equatable, Sendable {
  public private(set) var zoom: CGFloat = 1
  public private(set) var pan: CGPoint = .zero
  public init() {}
  public func display(_ point: CGPoint, in size: CGSize) -> CGPoint {
    CGPoint(
      x: (point.x - size.width / 2) * zoom + size.width / 2 + pan.x,
      y: (point.y - size.height / 2) * zoom + size.height / 2 + pan.y)
  }
  public func inverse(_ point: CGPoint, in size: CGSize) -> CGPoint {
    CGPoint(
      x: (point.x - size.width / 2 - pan.x) / zoom + size.width / 2,
      y: (point.y - size.height / 2 - pan.y) / zoom + size.height / 2)
  }
  public func displayRect(_ rect: CGRect, in size: CGSize) -> CGRect {
    CGRect(
      origin: display(rect.origin, in: size),
      size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
  }
  public mutating func move(_ delta: CGPoint, geometry: DisplayGeometry) {
    pan.x += delta.x
    pan.y += delta.y
    constrain(geometry)
  }
  public mutating func scale(by factor: CGFloat, anchor: CGPoint, geometry: DisplayGeometry) {
    guard factor.isFinite, factor > 0 else { return }
    let before = inverse(anchor, in: geometry.viewport)
    zoom = min(6, max(1, zoom * factor))
    let after = display(before, in: geometry.viewport)
    pan.x += anchor.x - after.x
    pan.y += anchor.y - after.y
    constrain(geometry)
  }
  private mutating func constrain(_ geometry: DisplayGeometry) {
    let x = max(0, (geometry.imageRect.width * zoom - geometry.viewport.width) / 2)
    let y = max(0, (geometry.imageRect.height * zoom - geometry.viewport.height) / 2)
    pan.x = min(x, max(-x, pan.x))
    pan.y = min(y, max(-y, pan.y))
  }
}

/// Keep fractional movement and split signed-byte packets without replacement coalescing.
public struct MotionAccumulator: Sendable {
  private var x = 0.0, y = 0.0
  public init() {}
  public mutating func consume(dx: Double, dy: Double, limit: Int = 127) -> [(Int, Int)] {
    guard dx.isFinite, dy.isFinite, limit > 0 else { return [] }
    x += dx
    y += dy
    var ix = Int(x.rounded(.towardZero))
    var iy = Int(y.rounded(.towardZero))
    x -= Double(ix)
    y -= Double(iy)
    var packets: [(Int, Int)] = []
    while ix != 0 || iy != 0 {
      let px = max(-limit, min(limit, ix))
      let py = max(-limit, min(limit, iy))
      packets.append((px, py))
      ix -= px
      iy -= py
    }
    return packets
  }
}

public enum MobileMouseMode: String, Codable, CaseIterable, Sendable {
  case absolute = "Absolute"
  case trackpad = "Trackpad"
}
