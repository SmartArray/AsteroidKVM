import Combine
import CometCore
import Foundation

// One configured local service, shared by device-specific caches.
@MainActor public final class LocalPerception: ObservableObject {
  public static let shared = LocalPerception()
  @Published public private(set) var settings: PerceptionSettings
  @Published public private(set) var health: ParserHealth?
  @Published public private(set) var status = "Not checked"
  public private(set) var generation = UUID()
  private let defaults: UserDefaults
  private let credentials = PasswordStore(service: "app.asteroidkvm.local-parser")
  private let profile = ConnectionProfile(name: "Local parser", host: "127.0.0.1", port: 9120)
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    settings =
      defaults.data(forKey: "localPerceptionSettings").flatMap {
        try? JSONDecoder().decode(PerceptionSettings.self, from: $0)
      } ?? PerceptionSettings()
  }
  public func save(_ value: PerceptionSettings, token: String? = nil) throws {
    _ = try value.validatedURL(path: "health")
    if let token, !token.isEmpty {
      try credentials.save(token, for: profile)
    }
    defaults.set(try JSONEncoder().encode(value), forKey: "localPerceptionSettings")
    settings = value
    generation = UUID()
    health = nil
    status = value.enabled ? "Not checked" : "Disabled"
  }
  public func client() throws -> OmniParserClient {
    guard settings.enabled else {
      throw PerceptionError(
        "PARSER_UNAVAILABLE",
        "Local UI parsing is disabled. Enable it in Settings → Local UI Parsing. Raw screen and HID tools remain available."
      )
    }
    _ = try settings.validatedURL(path: "health")
    return OmniParserClient(
      settings: settings,
      token: try credentials.password(for: profile) ?? "")
  }
  public func checkHealth() async {
    let ticket = generation
    status = "Connecting…"
    do {
      let result = try await client().health()
      guard ticket == generation else { return }
      health = result
      status =
        result.modelsLoaded
        ? "Ready · \(result.device.uppercased())"
        : "Service alive · models not ready\(result.error.map { " (\($0))" } ?? "")"
    } catch {
      guard ticket == generation else { return }
      health = nil
      status = error.localizedDescription
    }
  }
}
