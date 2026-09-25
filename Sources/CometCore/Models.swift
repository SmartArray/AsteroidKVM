// Keep protocol values lossless so configuration updates preserve fields owned by firmware.
import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  // Decode booleans before numbers because Foundation bridges both through NSNumber.
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let v = try? c.decode(Bool.self) {
      self = .bool(v)
    } else if let v = try? c.decode(Double.self) {
      self = .number(v)
    } else if let v = try? c.decode(String.self) {
      self = .string(v)
    } else if let v = try? c.decode([String: JSONValue].self) {
      self = .object(v)
    } else {
      self = .array(try c.decode([JSONValue].self))
    }
  }

  // Encode the original JSON structure without flattening firmware configuration.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .object(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .number(let v): try c.encode(v)
    case .bool(let v): try c.encode(v)
    case .null: try c.encodeNil()
    }
  }

  // Typed accessors make optional capability discovery explicit at call sites.
  public subscript(_ key: String) -> JSONValue { object[key] ?? .null }
  public var object: [String: JSONValue] {
    if case .object(let v) = self { return v }
    return [:]
  }
  public var array: [JSONValue] {
    if case .array(let v) = self { return v }
    return []
  }
  public var string: String? {
    if case .string(let v) = self { return v }
    return nil
  }
  public var number: Double? {
    if case .number(let v) = self { return v }
    return nil
  }
  public var bool: Bool? {
    if case .bool(let v) = self { return v }
    return nil
  }
  public var text: String {
    string ?? number.map { Int(exactly: $0).map(String.init) ?? String($0) } ?? bool.map(
      String.init) ?? ""
  }

  // Convert untrusted JSON numbers exactly before applying protocol-specific bounds; never trap on overflow.
  public func integer(in range: ClosedRange<Int> = Int.min...Int.max) -> Int? {
    guard let number, number.isFinite, let value = Int(exactly: number), range.contains(value)
    else { return nil }
    return value
  }

  // Decode protocol values without losing unknown object fields.
  public static func decode(_ data: Data) throws -> JSONValue {
    try JSONDecoder().decode(Self.self, from: data)
  }

  // Encode protocol values through JSONEncoder so payload text is escaped correctly.
  public func data() throws -> Data { try JSONEncoder().encode(self) }
}

// Persist connection identity and preferences only; secrets live in memory or Keychain.
public struct ConnectionProfile: Codable, Identifiable, Equatable, Sendable {
  public var id = UUID()
  public var name: String
  public var host: String
  public var port: Int
  public var scheme: String
  public var username: String
  public var rememberPassword = false
  public var certificateSHA256: String?
  public var keymap = "en-us"
  public var mcp: MCPPreferences?
  public var nativeLayout = false
  // Optional storage keeps profiles saved before this preference compatible with decoding.
  public static let defaultNativeTypingIntervalMilliseconds = 50
  private var nativeTypingIntervalOverride: Int?
  public var nativeTypingIntervalMilliseconds: Int {
    get { min(1000, max(0, nativeTypingIntervalOverride ?? Self.defaultNativeTypingIntervalMilliseconds)) }
    set { nativeTypingIntervalOverride = min(1000, max(0, newValue)) }
  }
  public var pasteEnabled = true
  public var scaleMode = ScaleMode.fit
  public var rotation = 0
  public var muted = false
  public var mouseSensitivity = 1.0
  public var scrollSensitivity = 1.0
  public var keyboardEnabled = true
  public var mouseEnabled = true
  public var mousePollingMilliseconds = 10.0
  public var reverseScrolling = false

  // Reject URL injection and credentials in hosts before constructing an endpoint.
  public init(
    name: String, host: String, port: Int = 443, scheme: String = "https",
    username: String = "admin"
  ) {
    self.name = name
    self.host = host
    self.port = port
    self.scheme = scheme
    self.username = username
  }
  public var baseURL: URL? {
    guard ["http", "https"].contains(scheme), (1...65535).contains(port),
      !host.isEmpty, !host.contains("/"), !host.contains("@"), !host.contains("?"),
      !host.contains("#")
    else { return nil }
    var c = URLComponents()
    c.scheme = scheme
    c.host = host
    c.port = port
    return c.url
  }
  public var credentialAccount: String { "\(scheme)://\(host.lowercased()):\(port)/\(username)" }

  // Encode identity as a tuple so delimiters in account names cannot alias another agent target.
  public var agentIdentity: String {
    let fields = [scheme, host.lowercased(), String(port), username, certificateSHA256 ?? ""]
    return String(decoding: (try? JSONEncoder().encode(fields)) ?? Data(), as: UTF8.self)
  }

  // A certificate exception belongs to its original endpoint, even when a profile UUID is reused.
  public func securingReplacement(of previous: ConnectionProfile) -> ConnectionProfile {
    var result = self
    if scheme != previous.scheme || host.lowercased() != previous.host.lowercased()
      || port != previous.port
    {
      result.certificateSHA256 = nil
    }
    return result
  }
}

// Report connection phases separately from video signal status and transient operations.
public enum ConnectionPhase: String, Sendable {
  case disconnected = "Disconnected"
  case connecting = "Connecting…"
  case authenticating = "Authentication required"
  case connected = "Connected"
  case reconnecting = "Reconnecting…"
  case noSignal = "No HDMI signal"
}

// Derive optional functions from explicit state rather than product or firmware nicknames.
public struct DeviceState: Sendable {
  public var keymaps: JSONValue = .null
  public var streamer: JSONValue = .null
  public var hid: JSONValue = .null
  public var config: JSONValue = .null
  public var system: JSONValue = .null
  public var functions: JSONValue = .null
  public var hardware: JSONValue = .null
  public init() {}
  public var mappedText: Bool {
    keymaps["mapped_text"].bool == true || keymaps["keymaps"]["mapped_text"].bool == true
  }
  public var availableKeymaps: [String] {
    keymaps["keymaps"]["available"].array.compactMap(\.string)
  }
  public var params: [String: JSONValue] { streamer["params"].object }
  public var online: Bool? { streamer["streamer"]["source"]["online"].bool }

  // Live streamer events are patches: status-only events must retain discovered encoder parameters and limits.
  public mutating func applyStreamerUpdate(_ update: JSONValue) {
    guard case .object(let fields) = update else { return }
    var current = streamer.object
    for (key, value) in fields {
      // Firmware defines features as a complete set; other sections may contain partial nested updates.
      current[key] =
        key == "features" ? value : Self.mergeStreamerField(current[key] ?? .null, value)
    }
    streamer = .object(current)
  }

  // Preserve omitted fields while honoring explicit nulls, scalar changes, and replacement arrays.
  private static func mergeStreamerField(_ old: JSONValue, _ update: JSONValue) -> JSONValue {
    guard case .object(let fields) = update else { return update }
    var result = old.object
    for (key, value) in fields {
      result[key] = mergeStreamerField(result[key] ?? .null, value)
    }
    return .object(result)
  }

}

// Reserve a typed extension point for future identity workflows without fabricating API support.
public protocol HardwareIdentityProvider: Sendable {

  // Reserve a read-only identity preview contract without inventing a device endpoint.
  func preview() async throws -> JSONValue

  // Reserve backend-aware proposal validation for future confirmed identity capabilities.
  func validate(_ proposal: JSONValue) async throws

  // Reserve explicit application of a validated identity proposal.
  func apply(_ proposal: JSONValue) async throws

  // Reserve restoration of a previously captured identity state.
  func restore() async throws
}

// Optional profile storage preserves older saved connections. Tokens stay in Keychain.
public struct MCPPreferences: Codable, Equatable, Sendable {
  public var enabled = false
  public var port = 9101
  public var allowControl = false
  public init() {}
}
