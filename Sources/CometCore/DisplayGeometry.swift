import CoreGraphics
// Use one geometry model for GPU presentation, remote mouse coordinates, and OCR cropping.
import Foundation

public enum ScaleMode: String, Codable, CaseIterable, Sendable {
  case fit = "Fit"
  case fill = "Fill"
  case actual = "Actual Size"
}

public struct DisplayGeometry: Equatable, Sendable {
  public var source: CGSize
  public var viewport: CGSize
  public var mode: ScaleMode
  public var rotation: Int
  public var backingScale: CGFloat
  public var pixelAspect: CGFloat

  // Source coordinates are pixels; viewport coordinates are AppKit points with a top-left origin.
  public init(
    source: CGSize, viewport: CGSize, mode: ScaleMode = .fit, rotation: Int = 0,
    backingScale: CGFloat = 1, pixelAspect: CGFloat = 1
  ) {
    self.source = source
    self.viewport = viewport
    self.mode = mode
    self.rotation = ((rotation % 360) + 360) % 360
    self.backingScale = max(backingScale, 1)
    self.pixelAspect = max(pixelAspect, 0.01)
  }
  public var valid: Bool {
    source.width > 0 && source.height > 0 && viewport.width > 0 && viewport.height > 0
  }
  public var imageRect: CGRect {
    guard valid else { return .zero }
    let size =
      rotation % 180 == 0
      ? CGSize(width: source.width * pixelAspect, height: source.height)
      : CGSize(width: source.height, height: source.width * pixelAspect)
    let fit = min(viewport.width / size.width, viewport.height / size.height)
    let fill = max(viewport.width / size.width, viewport.height / size.height)
    let scale = mode == .fit ? fit : mode == .fill ? fill : 1 / backingScale
    let w = size.width * scale
    let h = size.height * scale
    return CGRect(x: (viewport.width - w) / 2, y: (viewport.height - h) / 2, width: w, height: h)
  }
  public var visibleRect: CGRect { imageRect.intersection(CGRect(origin: .zero, size: viewport)) }

  // Clamp selections to the displayed image, including Fill cropping and letterboxing.
  public func clamp(_ point: CGPoint) -> CGPoint {
    let r = visibleRect
    return CGPoint(x: min(max(point.x, r.minX), r.maxX), y: min(max(point.y, r.minY), r.maxY))
  }

  // Invert presentation rotation and scaling into normalized source coordinates.
  public func sourcePoint(_ point: CGPoint) -> CGPoint {
    guard valid else { return .zero }
    let p = clamp(point)
    let r = imageRect
    let u = (p.x - r.minX) / r.width
    let v = (p.y - r.minY) / r.height
    switch rotation {
    case 90: return CGPoint(x: v, y: 1 - u)
    case 180: return CGPoint(x: 1 - u, y: 1 - v)
    case 270: return CGPoint(x: 1 - v, y: u)
    default: return CGPoint(x: u, y: v)
    }
  }

  // Clamp a selection to the displayed image before mapping its corners to source pixels.
  public func sourceCrop(from start: CGPoint, to end: CGPoint) -> CGRect {
    let a = sourcePoint(start)
    let b = sourcePoint(end)
    return CGRect(
      x: min(a.x, b.x) * source.width, y: min(a.y, b.y) * source.height,
      width: abs(a.x - b.x) * source.width, height: abs(a.y - b.y) * source.height
    ).integral
      .intersection(CGRect(origin: .zero, size: source))
  }

  // Convert source coordinates to the absolute signed HID range expected by Comet.
  public func hidPoint(_ point: CGPoint) -> (Int, Int) {
    let p = sourcePoint(point)
    return (Int((p.x * 65535 - 32768).rounded()), Int((p.y * 65535 - 32768).rounded()))
  }
}
