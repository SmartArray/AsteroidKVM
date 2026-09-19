// Isolate disk persistence and Keychain access from the connection and presentation layers.
import Foundation
import Security

public struct ProfileStore {
  public let url: URL
  public init(url: URL) { self.url = url }

  // Copy the prior app's data once, leaving it untouched until the new location is verified by a later save.
  public static func migrateIfNeeded(from legacyURL: URL, to url: URL) throws {
    let files = FileManager.default
    guard !files.fileExists(atPath: url.path), files.fileExists(atPath: legacyURL.path) else {
      return
    }
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try files.copyItem(at: legacyURL, to: url)
  }

  // Atomic writes avoid partially saved connection lists after interruption.
  public func save(_ profiles: [ConnectionProfile]) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(profiles).write(to: url, options: .atomic)
  }

  // Decode the saved profile list without introducing credential fields.
  public func load() throws -> [ConnectionProfile] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([ConnectionProfile].self, from: Data(contentsOf: url))
  }
}

public struct PasswordStore {
  public static let serviceName = "app.asteroidkvm.passwords"
  public static let legacyServiceName = "app.cometkvm.passwords"
  public let service: String
  private let legacyService: String?

  // Read an existing CometKVM secret once and duplicate it under the renamed app's Keychain service.
  public init(service: String = serviceName, legacyService: String? = nil) {
    self.service = service
    self.legacyService =
      legacyService ?? (service == Self.serviceName ? Self.legacyServiceName : nil)
  }

  // Scope each secret to scheme, host, port, and account rather than display name.
  private func query(_ profile: ConnectionProfile, service: String? = nil) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service ?? self.service,
      kSecAttrAccount as String: profile.credentialAccount,
    ]
  }

  // Keep the lookup result optional so a missing legacy credential does not become a migration error.
  private func storedPassword(for profile: ConnectionProfile, service: String) throws -> String? {
    var q = query(profile, service: service)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status) }
    return String(data: data, encoding: .utf8)
  }

  // Read the Keychain item scoped to the exact device endpoint and account.
  public func password(for profile: ConnectionProfile) throws -> String? {
    if let password = try storedPassword(for: profile, service: service) { return password }
    guard let legacyService, legacyService != service,
      let password = try storedPassword(for: profile, service: legacyService)
    else { return nil }
    try? save(password, for: profile)
    return password
  }

  // Update existing credentials without a delete/add gap; never put secrets in preferences.
  public func save(_ password: String, for profile: ConnectionProfile) throws {
    let q = query(profile)
    let attributes = [kSecValueData as String: Data(password.utf8)]
    let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var insertion = q.merging(attributes) { _, new in new }
      insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      let inserted = SecItemAdd(insertion as CFDictionary, nil)
      guard inserted == errSecSuccess else { throw KeychainError(inserted) }
    } else if status != errSecSuccess {
      throw KeychainError(status)
    }
  }

  // Delete only the explicitly selected device/account credential and treat an absent item as success.
  public func remove(for profile: ConnectionProfile) throws {
    for item in Set([service, legacyService].compactMap({ $0 })) {
      let status = SecItemDelete(query(profile, service: item) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainError(status)
      }
    }
  }
}

// Surface operating-system errors without including the password or account value.
public struct KeychainError: LocalizedError {
  let status: OSStatus
  public init(_ status: OSStatus) { self.status = status }
  public var errorDescription: String? { "Keychain could not complete the operation (\(status))." }
}
