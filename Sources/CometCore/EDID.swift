// Model monitor identity separately from complete EDID bytes so edits preserve unrelated capabilities.
import Foundation

public struct EDIDError: LocalizedError, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}

public struct EDIDIdentity: Equatable, Sendable {
  public var manufacturer: String
  public var product: UInt16
  public var serial: UInt32
  public var week: UInt8
  public var year: Int

  // This supplied identity is illustrative; it is not a claim to reproduce a particular Dell display.
  public static let example = EDIDIdentity(
    manufacturer: "DEL", product: 0xA034, serial: 0x3031_304C, week: 12, year: 2020)

  public init(manufacturer: String, product: UInt16, serial: UInt32, week: UInt8, year: Int) {
    self.manufacturer = manufacturer
    self.product = product
    self.serial = serial
    self.week = week
    self.year = year
  }

  // Zero is the EDID unknown-week sentinel; 255 is reserved for model-year encoding in EDID 1.4.
  public func validate() throws {
    guard manufacturer.utf8.count == 3,
      manufacturer.utf8.allSatisfy({ (65...90).contains($0) }),
      week <= 54 || week == 255, (1990...2245).contains(year)
    else {
      throw EDIDError("Use three uppercase manufacturer letters, week 0–54, and year 1990–2245.")
    }
  }
}

public enum EDIDPreset: String, CaseIterable, Identifiable, Sendable {
  case fullHD, laptop, quadHD
  public var id: String { rawValue }
  public var label: String {
    switch self {
    case .fullHD: return "1920 × 1080 · 60 Hz (16:9)"
    case .laptop: return "1920 × 1200 · 60 Hz (16:10)"
    case .quadHD: return "2560 × 1440 · 60 Hz (16:9)"
    }
  }

  // Fixed progressive CTA/CVT reduced-blanking timings avoid synthesizing timings from dimensions alone.
  // Columns: clock (10 kHz), active/blank pixels, active/blank lines, H front/sync, V front/sync, flags.
  public var timing: [Int] {
    switch self {
    case .fullHD: return [14850, 1920, 280, 1080, 45, 88, 44, 4, 5, 0x1e]
    case .laptop: return [15400, 1920, 160, 1200, 35, 48, 32, 3, 6, 0x1a]
    case .quadHD: return [24150, 2560, 160, 1440, 41, 48, 32, 3, 5, 0x1a]
    }
  }

  // All known Comet variants accept these conservative modes; unknown hardware is read-only for presets.
  public static func supported(model: String) -> [EDIDPreset] {
    let known = ["rm1", "rm1v1", "rm1v2", "rm10", "rm10rc", "rm10c4", "rm4pe", "rmq1"]
    let normalized = model.lowercased().replacingOccurrences(of: "gl-", with: "")
    return known.contains(normalized) ? allCases : []
  }

  // Build a complete two-block EDID with basic HDMI audio and one preferred progressive detailed timing.
  public func document(identity: EDIDIdentity = .example) throws -> EDIDDocument {
    var b = [UInt8](repeating: 0, count: 256)
    b.replaceSubrange(0..<8, with: [0, 255, 255, 255, 255, 255, 255, 0])
    b[18] = 1
    b[19] = 3
    b[20] = 0x80
    b[21] = 52
    b[22] = self == .laptop ? 32 : 29
    b[23] = 120
    b[24] = 0x0e
    b.replaceSubrange(25..<35, with: [0xee, 0x91, 0xa3, 0x54, 0x4c, 0x99, 0x26, 0x0f, 0x50, 0x54])
    // Advertise the baseline VGA fallback alongside the preferred high-resolution timing.
    b[35] = 0x20
    b.replaceSubrange(38..<54, with: [UInt8](repeating: 1, count: 16))

    // Pack the defined timing into the EDID detailed-timing bit fields without changing pixel-clock units.
    let t = timing
    let d: [Int] = [
      t[0] & 255, t[0] >> 8, t[1] & 255, t[2] & 255, (t[1] >> 8) << 4 | (t[2] >> 8),
      t[3] & 255, t[4] & 255, (t[3] >> 8) << 4 | (t[4] >> 8), t[5], t[6],
      t[7] << 4 | t[8], 0, 0x08, self == .laptop ? 0x40 : 0x22, 0x21, 0, 0, t[9],
    ]
    b.replaceSubrange(54..<72, with: d.map(UInt8.init))
    b.replaceSubrange(
      72..<90, with: [0, 0, 0, 0xfc, 0] + Array("AsteroidKVM\n".utf8) + [0])
    b.replaceSubrange(
      90..<108, with: [0, 0, 0, 0xfd, 0, 50, 75, 30, 95, 26, 0, 10, 32, 32, 32, 32, 32, 32])
    b.replaceSubrange(108..<126, with: [0, 0, 0, 0x10] + [UInt8](repeating: 0, count: 14))
    b[126] = 1

    // CTA audio and HDMI vendor data retain sound; the explicit 260 MHz TMDS limit accommodates the 1440p clock.
    b.replaceSubrange(
      128..<148,
      with: [2, 3, 20, 0x40, 0x23, 9, 7, 7, 0x83, 1, 0, 0, 0x67, 3, 12, 0, 0x10, 0, 0, 52])
    EDIDDocument.fixChecksums(&b)
    return try EDIDDocument(bytes: b).replacingIdentity(identity)
  }
}

public struct EDIDDocument: Equatable, Sendable {
  public let bytes: [UInt8]
  public var hex: String { bytes.map { String(format: "%02X", $0) }.joined() }

  // Reject malformed or oversized documents before interpreting offsets or sending them to hardware.
  public init(bytes: [UInt8]) throws {
    guard [128, 256].contains(bytes.count),
      Array(bytes.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0],
      bytes[18] == 1, [3, 4].contains(bytes[19]), Int(bytes[126]) == bytes.count / 128 - 1
    else {
      throw EDIDError("Expected a complete EDID 1.3/1.4 document with one or two 128-byte blocks.")
    }
    for offset in stride(from: 0, to: bytes.count, by: 128) {
      guard bytes[offset..<offset + 128].reduce(0, { $0 + Int($1) }) % 256 == 0 else {
        throw EDIDError("EDID checksum is invalid.")
      }
    }
    self.bytes = bytes
  }

  // Hex decoding permits whitespace only; arbitrary text and incomplete byte pairs are not silently accepted.
  public init(hex: String) throws {
    let chars = Array(hex.filter { !$0.isWhitespace })
    guard [256, 512].contains(chars.count) else { throw EDIDError("Invalid EDID length.") }
    var data: [UInt8] = []
    for i in stride(from: 0, to: chars.count, by: 2) {
      guard let value = UInt8(String(chars[i...i + 1]), radix: 16) else {
        throw EDIDError("Invalid EDID hexadecimal data.")
      }
      data.append(value)
    }
    try self.init(bytes: data)
  }

  // Decode the EISA manufacturer code and little-endian product/serial identity independently of timings.
  public var identity: EDIDIdentity {
    let code = Int(bytes[8]) << 8 | Int(bytes[9])
    let name = [10, 5, 0].map { String(UnicodeScalar(((code >> $0) & 31) + 64)!) }.joined()
    return EDIDIdentity(
      manufacturer: name, product: UInt16(bytes[10]) | UInt16(bytes[11]) << 8,
      serial: (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[12 + $1]) << ($1 * 8) },
      week: bytes[16], year: Int(bytes[17]) + 1990)
  }

  // Prefer the first detailed timing; unknown/default firmware state is represented outside this document.
  public var preferredMode: String {
    let d = Array(bytes[54..<72])
    let clock = (Int(d[0]) | Int(d[1]) << 8) * 10000
    guard clock > 0 else { return "Not specified" }
    let width = Int(d[2]) | Int(d[4] & 0xf0) << 4
    let height = Int(d[5]) | Int(d[7] & 0xf0) << 4
    let totalX = width + Int(d[3]) + (Int(d[4] & 15) << 8)
    let totalY = height + Int(d[6]) + (Int(d[7] & 15) << 8)
    guard totalX > 0, totalY > 0 else { return "Invalid timing" }
    return "\(width) × \(height) · \(Int((Double(clock) / Double(totalX * totalY)).rounded())) Hz"
  }

  // Identity-only edits touch bytes 8–17 and the base checksum; audio and unknown extension data survive intact.
  public func replacingIdentity(_ identity: EDIDIdentity) throws -> EDIDDocument {
    try identity.validate()
    guard identity.week != 255 || bytes[19] == 4 else {
      throw EDIDError("Model-year encoding requires EDID 1.4.")
    }
    var b = bytes
    let letters = Array(identity.manufacturer.utf8).map { Int($0) - 64 }
    let code = letters[0] << 10 | letters[1] << 5 | letters[2]
    b[8] = UInt8(code >> 8)
    b[9] = UInt8(code & 255)
    b[10] = UInt8(identity.product & 255)
    b[11] = UInt8(identity.product >> 8)
    for i in 0..<4 { b[12 + i] = UInt8((identity.serial >> (i * 8)) & 255) }
    b[16] = identity.week
    b[17] = UInt8(identity.year - 1990)
    Self.fixChecksums(&b)
    return try EDIDDocument(bytes: b)
  }

  // Every edited block receives its own checksum, as required by EDID rather than a whole-document checksum.
  static func fixChecksums(_ bytes: inout [UInt8]) {
    for offset in stride(from: 0, to: bytes.count, by: 128) {
      bytes[offset + 127] = UInt8(
        (256 - bytes[offset..<offset + 127].reduce(0, { $0 + Int($1) }) % 256) % 256)
    }
  }
}
