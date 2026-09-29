import Combine
import CometCore
import Foundation

// One configured local service, shared by device-specific caches; it may be app-managed or external.
@MainActor public final class LocalPerception: ObservableObject {
  public static let shared = LocalPerception()
  @Published public private(set) var settings: PerceptionSettings
  @Published public private(set) var health: ParserHealth?
  @Published public private(set) var status = "Not checked"
  @Published public private(set) var usesManagedService: Bool
  @Published public private(set) var startWithApp: Bool
  public private(set) var generation = UUID()
  private let defaults: UserDefaults
  private let credentials = PasswordStore(service: "app.asteroidkvm.local-parser")
  private let profile = ConnectionProfile(name: "Local parser", host: "127.0.0.1", port: 9120)
  private let managedProfile = ConnectionProfile(
    name: "Managed parser", host: "managed-parser.local", port: 9120)
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    usesManagedService =
      defaults.object(forKey: "parserManagedService") as? Bool
      ?? (defaults.data(forKey: "localPerceptionSettings") == nil)
    startWithApp = defaults.bool(forKey: "parserStartWithApp")
    settings =
      defaults.data(forKey: "localPerceptionSettings").flatMap {
        try? JSONDecoder().decode(PerceptionSettings.self, from: $0)
      } ?? PerceptionSettings()
  }
  public func setManagedService(_ value: Bool) {
    defaults.set(value, forKey: "parserManagedService")
    usesManagedService = value
    generation = UUID()
    health = nil
    status = "Not checked"
  }
  public func setStartWithApp(_ value: Bool) {
    defaults.set(value, forKey: "parserStartWithApp")
    startWithApp = value
  }
  public func useManagedInstallation(_ draft: PerceptionSettings? = nil) throws {
    var value = draft ?? settings
    value.enabled = true
    try credentials.save(LocalParserManager.shared.accessToken(), for: managedProfile)
    try save(value)
    setManagedService(true)
  }
  public func startManagedIfRequested() {
    guard usesManagedService, startWithApp, settings.enabled,
      LocalParserManager.shared.installedVersion != nil
    else { return }
    do {
      try useManagedInstallation()
      LocalParserManager.shared.start(settings: settings) { await self.checkHealth() }
    } catch { status = error.localizedDescription }
  }
  public func save(_ value: PerceptionSettings, token: String? = nil) throws {
    _ = try value.validatedURL(path: "health")
    if let token, !token.isEmpty {
      try credentials.save(token, for: usesManagedService ? managedProfile : profile)
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
      token: try credentials.password(for: usesManagedService ? managedProfile : profile) ?? "")
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
