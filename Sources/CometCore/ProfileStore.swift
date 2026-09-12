// Isolate disk persistence and Keychain access from the connection and presentation layers.
import Foundation
import Security

public struct ProfileStore {
  public let url: URL
  public init(url: URL) { self.url = url }

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
  public let service: String
  public init(service: String = "app.cometkvm.passwords") { self.service = service }

  // Scope each secret to scheme, host, port, and account rather than display name.
  private func query(_ profile: ConnectionProfile) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: profile.credentialAccount,
    ]
  }

  // Read the Keychain item scoped to the exact device endpoint and account.
  public func password(for profile: ConnectionProfile) throws -> String? {
    var q = query(profile)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status) }
    return String(data: data, encoding: .utf8)
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
    let status = SecItemDelete(query(profile) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status)
    }
  }
}

// Surface operating-system errors without including the password or account value.
public struct KeychainError: LocalizedError {
  let status: OSStatus
  public init(_ status: OSStatus) { self.status = status }
  public var errorDescription: String? { "Keychain could not complete the operation (\(status))." }
}
