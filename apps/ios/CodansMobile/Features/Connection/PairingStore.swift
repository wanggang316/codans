import CodansRemote
import ComposableArchitecture
import Foundation
import Security

/// Paired Macs on this phone. Metadata goes to `UserDefaults`; each
/// pre-shared key goes to the Keychain as a this-device-only item, so it is
/// never synced to iCloud or restored onto another phone.
nonisolated struct PairingStore: Sendable {
  struct Snapshot: Equatable, Sendable {
    var gateways: [PairedGateway]
    /// The Mac the app shows; the app connects to one Mac at a time.
    var activeID: UUID?
  }

  var load: @Sendable () -> Snapshot
  /// Stores the key and the record, and makes the new pairing active.
  var save: @Sendable (_ payload: PairingPayload, _ at: Date) throws -> PairedGateway
  /// Deletes the key first, then the record.
  var remove: @Sendable (_ deviceID: UUID) -> Void
  var setActive: @Sendable (_ deviceID: UUID?) -> Void
  /// The stored key for `gateway`, or nil when the Keychain no longer has it.
  var credential: @Sendable (_ gateway: PairedGateway) -> RemoteTLS.PSKCredential?
}

nonisolated extension PairingStore: DependencyKey {
  static let liveValue: PairingStore = {
    let live = LivePairingStore()
    return PairingStore(
      load: { live.load() },
      save: { try live.save($0, at: $1) },
      remove: { live.remove($0) },
      setActive: { live.setActive($0) },
      credential: { live.credential(for: $0) }
    )
  }()

  static let testValue = PairingStore(
    load: unimplemented("PairingStore.load", placeholder: Snapshot(gateways: [], activeID: nil)),
    save: unimplemented("PairingStore.save"),
    remove: unimplemented("PairingStore.remove"),
    setActive: unimplemented("PairingStore.setActive"),
    credential: unimplemented("PairingStore.credential", placeholder: nil)
  )

  /// An in-memory store for previews and tests that exercise the pairing
  /// path end to end.
  static func inMemory(_ initial: Snapshot = Snapshot(gateways: [], activeID: nil)) -> PairingStore {
    let state = LockIsolated((snapshot: initial, keys: [UUID: RemoteTLS.PSKCredential]()))
    return PairingStore(
      load: { state.value.snapshot },
      save: { payload, date in
        let gateway = PairedGateway(payload: payload, pairedAt: date)
        state.withValue {
          $0.snapshot.gateways.removeAll { $0.deviceID == gateway.deviceID }
          $0.snapshot.gateways.append(gateway)
          $0.snapshot.activeID = gateway.deviceID
          $0.keys[gateway.deviceID] = payload.credential
        }
        return gateway
      },
      remove: { id in
        state.withValue {
          $0.keys[id] = nil
          $0.snapshot.gateways.removeAll { $0.deviceID == id }
          if $0.snapshot.activeID == id { $0.snapshot.activeID = nil }
        }
      },
      setActive: { id in state.withValue { $0.snapshot.activeID = id } },
      credential: { gateway in state.value.keys[gateway.deviceID] }
    )
  }
}

nonisolated extension DependencyValues {
  var pairingStore: PairingStore {
    get { self[PairingStore.self] }
    set { self[PairingStore.self] = newValue }
  }
}

/// Keychain + `UserDefaults` backing of `PairingStore.liveValue`.
private nonisolated final class LivePairingStore: Sendable {
  private static let keychainService = "com.gumpw.codans.mobile.pairing"
  private static let gatewaysKey = "pairing.gateways.v1"
  private static let activeKey = "pairing.activeID"

  private let lock = NSLock()
  private var defaults: UserDefaults { .standard }

  func load() -> PairingStore.Snapshot {
    lock.withLock {
      let gateways =
        defaults.data(forKey: Self.gatewaysKey)
        .flatMap { try? JSONDecoder().decode([PairedGateway].self, from: $0) } ?? []
      let active = defaults.string(forKey: Self.activeKey).flatMap(UUID.init(uuidString:))
      return PairingStore.Snapshot(
        gateways: gateways,
        activeID: gateways.contains { $0.deviceID == active } ? active : gateways.first?.deviceID
      )
    }
  }

  func save(_ payload: PairingPayload, at date: Date) throws -> PairedGateway {
    let gateway = PairedGateway(payload: payload, pairedAt: date)
    try Self.writeKey(payload.psk, account: Self.account(for: gateway))
    lock.withLock {
      var gateways = storedGateways()
      gateways.removeAll { $0.deviceID == gateway.deviceID }
      gateways.append(gateway)
      store(gateways)
      defaults.set(gateway.deviceID.uuidString, forKey: Self.activeKey)
    }
    return gateway
  }

  func remove(_ deviceID: UUID) {
    lock.withLock {
      var gateways = storedGateways()
      if let gateway = gateways.first(where: { $0.deviceID == deviceID }) {
        Self.deleteKey(account: Self.account(for: gateway))
      }
      gateways.removeAll { $0.deviceID == deviceID }
      store(gateways)
      if defaults.string(forKey: Self.activeKey) == deviceID.uuidString {
        defaults.removeObject(forKey: Self.activeKey)
      }
    }
  }

  func setActive(_ deviceID: UUID?) {
    lock.withLock {
      if let deviceID {
        defaults.set(deviceID.uuidString, forKey: Self.activeKey)
      } else {
        defaults.removeObject(forKey: Self.activeKey)
      }
    }
  }

  func credential(for gateway: PairedGateway) -> RemoteTLS.PSKCredential? {
    Self.readKey(account: Self.account(for: gateway)).map {
      RemoteTLS.PSKCredential(identity: gateway.pskIdentity, key: $0)
    }
  }

  // MARK: - Internals

  private func storedGateways() -> [PairedGateway] {
    defaults.data(forKey: Self.gatewaysKey)
      .flatMap { try? JSONDecoder().decode([PairedGateway].self, from: $0) } ?? []
  }

  private func store(_ gateways: [PairedGateway]) {
    if let data = try? JSONEncoder().encode(gateways) {
      defaults.set(data, forKey: Self.gatewaysKey)
    }
  }

  private static func account(for gateway: PairedGateway) -> String {
    "\(gateway.serviceName)/\(gateway.deviceID.uuidString)"
  }

  private static func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    ]
  }

  private static func writeKey(_ key: Data, account: String) throws {
    deleteKey(account: account)
    var query = baseQuery(account: account)
    query[kSecValueData as String] = key
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
  }

  private static func readKey(account: String) -> Data? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
    return result as? Data
  }

  private static func deleteKey(account: String) {
    SecItemDelete(baseQuery(account: account) as CFDictionary)
  }
}
