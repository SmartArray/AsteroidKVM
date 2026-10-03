// Package the full-bleed artwork inside a rounded Dock icon without altering the master.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
  fatalError("Usage: prepare-mac-icon.swift source.png destination.png")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destinationURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
  let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width == image.height,
  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
  let context = CGContext(
    data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("Cannot load square icon artwork or create its rendering context") }

let bounds = CGRect(x: 64, y: 64, width: 896, height: 896)
context.interpolationQuality = .high
context.addPath(CGPath(roundedRect: bounds, cornerWidth: 200, cornerHeight: 200, transform: nil))
context.clip()
context.draw(image, in: bounds)

guard let rendered = context.makeImage(),
  let destination = CGImageDestinationCreateWithURL(
    destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Cannot encode macOS icon") }
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write macOS icon") }
