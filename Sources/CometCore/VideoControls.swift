// Match the inspected GLKVM web client presets, while respecting each device's advertised limits.
import Foundation

public struct VideoPreset: Identifiable, Sendable {
  public let id: Int
  public let name: String
  public let bitrate: Int
  public let gop: Int?
  public var parameters: [String: String] {
    var values = ["h264_bitrate": String(bitrate)]
    if let gop { values["h264_gop"] = String(gop) }
    return values
  }

  // Require the connected device’s supported parameters and limits before enabling a preset.
  public func supported(by state: DeviceState) -> Bool {
    guard state.params["h264_bitrate"] != nil, state.streamer["features"]["h264"].bool != false
    else { return false }
    let limits = state.streamer["limits"]["h264_bitrate"]
    guard let minimum = limits["min"].integer(in: 0...Int.max),
      let maximum = limits["max"].integer(in: minimum...Int.max),
      (minimum...maximum).contains(bitrate)
    else { return false }

    // A preset must satisfy every parameter it writes, including the advertised keyframe interval.
    if let gop {
      let bounds = state.streamer["limits"]["h264_gop"]
      guard let minimum = bounds["min"].number, let maximum = bounds["max"].number else {
        return false
      }
      return Double(gop) >= minimum && Double(gop) <= maximum
    }
    return true
  }
  public static let firmwarePresets = [
    VideoPreset(id: 5, name: "Auto", bitrate: 0, gop: nil),
    VideoPreset(id: 0, name: "Very Low", bitrate: 500, gop: 30),
    VideoPreset(id: 1, name: "Low", bitrate: 2_000, gop: 30),
    VideoPreset(id: 2, name: "Medium", bitrate: 5_000, gop: 60),
    VideoPreset(id: 3, name: "High", bitrate: 8_000, gop: 60),
    VideoPreset(id: 4, name: "Lossless (firmware preset)", bitrate: 20_000, gop: 60),
  ]
}
