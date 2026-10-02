// Construct offline EDID files through the same timing templates and validation as the app.
import CometCore
import Foundation

private let help = """
Usage: create-edid [options]

Construct a 256-byte HDMI EDID. Defaults: ASUS Display, AUS, 2560x1440 at 60 Hz.
Prints uppercase hex to stdout unless --output is provided. No KVM is contacted.

  --name TEXT           Display name, 1–13 printable ASCII characters (ASUS Display)
  --manufacturer ID     Three uppercase letters (AUS = ASUS)
  --product NUMBER      16-bit product code (0x24B2)
  --serial NUMBER       32-bit numeric serial (0x01010101)
  --week NUMBER         Manufacture week, 0–54; 0 means unspecified (33)
  --year NUMBER         Manufacture year, 1990–2245 (2020)
  --mode MODE           1920x1080, 1920x1200, or 2560x1440 (default)
  --format FORMAT       hex (default) or bin; binary requires --output
  --output PATH         Create a file; existing files are never overwritten
  --help, -h            Show this help

Numbers are decimal unless prefixed with 0x. All modes are progressive, about 60 Hz,
with VGA fallback and stereo HDMI audio. ASUS defaults retain the numeric identity
from the supplied EDID; this is a constructed profile, not a verified ASUS dump.

Examples:
  create-edid --name "ASUS Display" --output asus-1440p.hex
  create-edid --mode 1920x1080 --format bin --output asus-1080p.bin
  create-edid --name "ASUS Monitor" --serial 0x12345678
"""

private func number<T: FixedWidthInteger>(_ value: String, as: T.Type, option: String) throws -> T {
  let hex = value.lowercased().hasPrefix("0x")
  guard let result = T(hex ? String(value.dropFirst(2)) : value, radix: hex ? 16 : 10) else {
    throw EDIDError("Invalid or out-of-range value for \(option): \(value)")
  }
  return result
}

private func run() throws {
  let arguments = Array(CommandLine.arguments.dropFirst())
  if arguments == ["--help"] || arguments == ["-h"] {
    print(help)
    return
  }
  let allowed: Set<String> = [
    "--name", "--manufacturer", "--product", "--serial", "--week", "--year",
    "--mode", "--format", "--output",
  ]
  var values: [String: String] = [:]
  var index = 0
  while index < arguments.count {
    let key = arguments[index]
    guard allowed.contains(key) else { throw EDIDError("Unknown option: \(key). Use --help.") }
    guard values[key] == nil else { throw EDIDError("Option specified twice: \(key)") }
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
      throw EDIDError("Missing value for \(key)")
    }
    values[key] = arguments[index + 1]
    index += 2
  }
  let modes: [String: EDIDPreset] = [
    "1920x1080": .fullHD, "1920x1200": .laptop, "2560x1440": .quadHD,
  ]
  guard let preset = modes[values["--mode"] ?? "2560x1440"] else {
    throw EDIDError("Choose --mode 1920x1080, 1920x1200, or 2560x1440.")
  }
  let format = values["--format"] ?? "hex"
  guard ["hex", "bin"].contains(format) else { throw EDIDError("Choose --format hex or bin.") }
  guard format != "bin" || values["--output"] != nil else {
    throw EDIDError("Binary output requires --output PATH.")
  }
  let identity = EDIDIdentity(
    manufacturer: values["--manufacturer"] ?? "AUS",
    product: try number(values["--product"] ?? "0x24B2", as: UInt16.self, option: "--product"),
    serial: try number(values["--serial"] ?? "0x01010101", as: UInt32.self, option: "--serial"),
    week: try number(values["--week"] ?? "33", as: UInt8.self, option: "--week"),
    year: try number(values["--year"] ?? "2020", as: Int.self, option: "--year"))
  let document = try preset.document(identity: identity, displayName: values["--name"] ?? "ASUS Display")
  let data = format == "hex" ? Data((document.hex + "\n").utf8) : Data(document.bytes)
  if let path = values["--output"] {
    let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    // Exclusive creation avoids overwriting a monitor backup or following an existing output symlink.
    try data.write(to: url, options: .withoutOverwriting)
    let summary = "Created \(url.path): \(document.displayName ?? ""), \(document.identity.manufacturer), \(document.preferredMode), 256 bytes; checksums valid.\n"
    FileHandle.standardError.write(Data(summary.utf8))
  } else {
    FileHandle.standardOutput.write(data)
  }
}

do {
  try run()
} catch {
  FileHandle.standardError.write(Data("create-edid: \(error.localizedDescription)\n".utf8))
  exit(1)
}
