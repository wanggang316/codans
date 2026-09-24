import Foundation
import Testing

@testable import Codans
@testable import CodansCore
@testable import CodansIPC

@MainActor
struct PairedDeviceStoreTests {
  /// Whole seconds: the file stores ISO 8601 instants.
  private static let start = Date(timeIntervalSince1970: 1_790_000_000)

  @Test
  func pairedDevicesRoundTripThroughTheFile() throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent(PairedDeviceStore.fileName)
    let keys = InMemoryRemoteKeyStore()
    var clock = Self.start

    let store = PairedDeviceStore(fileURL: url, keys: keys, now: { clock })
    let phone = try store.beginPairing(name: "Phone", permission: .interactive)
    let tablet = try store.beginPairing(name: "Tablet")
    clock = Self.start.addingTimeInterval(30)
    store.recordConnection(phone.id)
    store.rename(tablet.id, to: "  iPad  ")

    let reloaded = PairedDeviceStore(fileURL: url, keys: keys, now: { clock })
    #expect(reloaded.devices == store.devices)
    let reloadedPhone = try #require(reloaded.device(phone.id))
    #expect(reloadedPhone.state == .active)
    #expect(reloadedPhone.permission == .interactive)
    #expect(reloadedPhone.lastSeenAt == Self.start.addingTimeInterval(30))
    #expect(reloaded.device(tablet.id)?.name == "iPad")
    #expect(reloaded.device(tablet.id)?.permission == .readOnly)

    // The key never lands in the JSON file.
    let json = try String(contentsOf: url, encoding: .utf8)
    let key = try #require(keys.key(for: phone.id))
    #expect(key.count == 32)
    #expect(!json.contains(key.base64EncodedString()))
    #expect(json.contains("\"version\" : 1"))
  }

  @Test
  func revokeRemovesKeyAndRecordAndNotifies() throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let keys = InMemoryRemoteKeyStore()
    let store = PairedDeviceStore(fileURL: dir.appendingPathComponent("d.json"), keys: keys)
    var revoked: [UUID] = []
    var credentialChanges = 0
    store.onRevoked = { revoked.append($0) }
    store.onCredentialsChanged = { credentialChanges += 1 }

    let device = try store.beginPairing()
    #expect(store.credentials().map(\.identity) == [device.id.uuidString])
    store.revoke(device.id)

    #expect(keys.key(for: device.id) == nil)
    #expect(store.devices.isEmpty)
    #expect(store.permission(for: device.id) == nil)
    #expect(store.credentials().isEmpty)
    #expect(revoked == [device.id])
    #expect(credentialChanges == 2)
  }

  @Test
  func permissionChangeIsVisibleImmediately() throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = PairedDeviceStore(fileURL: dir.appendingPathComponent("d.json"), keys: InMemoryRemoteKeyStore())
    let device = try store.beginPairing(permission: .interactive)
    store.setPermission(device.id, to: .readOnly)
    #expect(store.permission(for: device.id) == .readOnly)
  }

  @Test
  func unusedPendingPairingExpires() throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let keys = InMemoryRemoteKeyStore()
    var clock = Self.start
    let store = PairedDeviceStore(fileURL: dir.appendingPathComponent("d.json"), keys: keys, now: { clock })
    let pending = try store.beginPairing()
    let used = try store.beginPairing()
    store.recordConnection(used.id)

    clock = Self.start.addingTimeInterval(PairedDeviceStore.pendingLifetimeSeconds - 1)
    #expect(store.pruneExpiredPending().isEmpty)

    clock = Self.start.addingTimeInterval(PairedDeviceStore.pendingLifetimeSeconds)
    // Expired codes stop authenticating even before the prune runs.
    #expect(store.credentials().map(\.identity) == [used.id.uuidString])
    #expect(store.pruneExpiredPending() == [pending.id])
    #expect(keys.key(for: pending.id) == nil)
    #expect(store.devices.map(\.id) == [used.id])
  }

  @Test
  func futureVersionFileIsSetAsideNotOverwritten() throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent(PairedDeviceStore.fileName)
    try Data(#"{"version": 2, "devices": []}"#.utf8).write(to: url)

    let store = PairedDeviceStore(fileURL: url, keys: InMemoryRemoteKeyStore())
    #expect(store.devices.isEmpty)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names.contains { $0.hasPrefix("\(PairedDeviceStore.fileName).v2.") && $0.hasSuffix(".bak") })
    #expect(!names.contains(PairedDeviceStore.fileName))
  }

  private static func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("paired-device-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
