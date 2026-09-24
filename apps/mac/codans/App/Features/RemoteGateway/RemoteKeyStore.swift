import CodansCore
import Foundation
import Security

/// Where paired devices' pre-shared keys live. The production store is the
/// Keychain; tests use an in-memory one so they never touch the user's
/// keychain.
protocol RemoteKeyStore: AnyObject {
  func key(for deviceID: UUID) -> Data?
  func setKey(_ key: Data, for deviceID: UUID) throws
  func deleteKey(for deviceID: UUID)
}

/// Generic-password items, one per device: service
/// `com.gumpw.codans.remote.<channel slug>`, account = device ID. Readable
/// after first unlock so the gateway works while the screen is locked, and
/// never synchronized to iCloud.
final class KeychainRemoteKeyStore: RemoteKeyStore {
  struct KeychainError: Error, Equatable {
    let status: OSStatus
  }

  let service: String

  init(channel: BuildChannel = .current) {
    self.service = "com.gumpw.codans.remote.\(channel.slug)"
  }

  func key(for deviceID: UUID) -> Data? {
    var query = baseQuery(deviceID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  func setKey(_ key: Data, for deviceID: UUID) throws {
    deleteKey(for: deviceID)
    var item = baseQuery(deviceID)
    item[kSecValueData as String] = key
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    item[kSecAttrLabel as String] = "codans remote device key"
    let status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw KeychainError(status: status) }
  }

  func deleteKey(for deviceID: UUID) {
    SecItemDelete(baseQuery(deviceID) as CFDictionary)
  }

  private func baseQuery(_ deviceID: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: deviceID.uuidString,
      kSecAttrSynchronizable as String: false,
    ]
  }
}

/// In-memory key store for tests.
final class InMemoryRemoteKeyStore: RemoteKeyStore {
  private(set) var keys: [UUID: Data] = [:]

  func key(for deviceID: UUID) -> Data? { keys[deviceID] }
  func setKey(_ key: Data, for deviceID: UUID) throws { keys[deviceID] = key }
  func deleteKey(for deviceID: UUID) { keys[deviceID] = nil }
}
