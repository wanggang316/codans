import CodansCore
import CodansIPC
import CodansRemote
import Foundation
import Observation
import os

/// Single writer of `remote-devices.json` and of the devices' Keychain
/// keys. The file sits in `AppDirectories.configDirectory`, so Debug and
/// Release builds keep separate device lists, like every other codans
/// store.
///
/// Revocation deletes the key first, then the record: a crash in between
/// leaves a record whose device can no longer authenticate, never a live
/// key with no visible record.
@MainActor
@Observable
final class PairedDeviceStore {
  static let fileName = "remote-devices.json"
  /// How long an unused pairing code stays valid.
  static let pendingLifetime: Duration = .seconds(600)

  private(set) var devices: [PairedDevice] = []

  @ObservationIgnored private let fileURL: URL
  @ObservationIgnored private let keys: RemoteKeyStore
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private let logger = Logger(subsystem: "com.gumpw.codans.remote", category: "pairing")

  /// Fired after the set of devices that may authenticate changes
  /// (pairing, revocation, expiry) — the gateway rebuilds its listener.
  @ObservationIgnored var onCredentialsChanged: (() -> Void)?
  /// Fired after a device is revoked, so its live connections are closed.
  @ObservationIgnored var onRevoked: ((UUID) -> Void)?

  init(
    fileURL: URL = PairedDeviceStore.defaultURL(),
    keys: RemoteKeyStore,
    now: @escaping () -> Date = Date.init
  ) {
    self.fileURL = fileURL
    self.keys = keys
    self.now = now
    self.devices = load()
  }

  static func defaultURL(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
    AppDirectories.configDirectory(home: home).appendingPathComponent(fileName, isDirectory: false)
  }

  func device(_ id: UUID) -> PairedDevice? {
    devices.first { $0.id == id }
  }

  /// Permission for a request from `id`; nil when the device is unknown
  /// (never paired, or revoked since it connected).
  func permission(for id: UUID) -> IPC.RemotePermission? {
    device(id)?.permission
  }

  // MARK: - Pairing

  /// Issues a new pending device with a fresh random key stored in the
  /// Keychain. The caller shows the key to the user as a pairing code.
  @discardableResult
  func beginPairing(
    name: String = "New device",
    permission: IPC.RemotePermission = .readOnly
  ) throws -> PairedDevice {
    let device = PairedDevice(
      id: UUID(),
      name: name,
      permission: permission,
      state: .pending,
      createdAt: now(),
      lastSeenAt: nil
    )
    try keys.setKey(try PairingPayload.generateKey(), for: device.id)
    devices.append(device)
    save()
    logger.info("pairing issued for device \(device.id.uuidString, privacy: .public)")
    onCredentialsChanged?()
    return device
  }

  func key(for id: UUID) -> Data? {
    keys.key(for: id)
  }

  /// Every credential the TLS listener should accept: devices that have a
  /// key, minus pending ones past their lifetime.
  func credentials() -> [RemoteTLS.PSKCredential] {
    devices.compactMap { device in
      guard !isExpired(device), let key = keys.key(for: device.id) else { return nil }
      return RemoteTLS.PSKCredential(identity: device.pskIdentity, key: key)
    }
  }

  /// A device completed a handshake: a pending pairing becomes active, and
  /// `lastSeenAt` is stamped once per connection rather than per request.
  func recordConnection(_ id: UUID) {
    guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
    devices[index].state = .active
    devices[index].lastSeenAt = now()
    save()
  }

  // MARK: - Management

  func rename(_ id: UUID, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let index = devices.firstIndex(where: { $0.id == id }) else { return }
    devices[index].name = trimmed
    save()
  }

  /// Takes effect on the device's next request; no reconnect needed.
  func setPermission(_ id: UUID, to permission: IPC.RemotePermission) {
    guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
    devices[index].permission = permission
    save()
    logger.info(
      "device \(id.uuidString, privacy: .public) permission → \(permission.rawValue, privacy: .public)")
  }

  func revoke(_ id: UUID) {
    guard devices.contains(where: { $0.id == id }) else { return }
    keys.deleteKey(for: id)
    devices.removeAll { $0.id == id }
    save()
    logger.info("device \(id.uuidString, privacy: .public) revoked")
    onRevoked?(id)
    onCredentialsChanged?()
  }

  /// Discards pending pairings older than `pendingLifetime`, with their
  /// keys. Returns the discarded ids.
  @discardableResult
  func pruneExpiredPending() -> [UUID] {
    let expired = devices.filter(isExpired).map(\.id)
    for id in expired { revoke(id) }
    return expired
  }

  /// When the oldest still-pending pairing code stops working, or nil when
  /// nothing is pending.
  func nextPendingExpiry() -> Date? {
    devices.filter { $0.state == .pending }
      .map { $0.createdAt.addingTimeInterval(Self.pendingLifetimeSeconds) }
      .min()
  }

  /// The store's clock, so timers measure against the same time as
  /// `isExpired`.
  func currentDate() -> Date {
    now()
  }

  func isExpired(_ device: PairedDevice) -> Bool {
    guard device.state == .pending else { return false }
    return now().timeIntervalSince(device.createdAt) >= Self.pendingLifetimeSeconds
  }

  static var pendingLifetimeSeconds: TimeInterval {
    TimeInterval(pendingLifetime.components.seconds)
  }

  // MARK: - Persistence

  private func load() -> [PairedDevice] {
    struct VersionProbe: Decodable { let version: Int }
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    do {
      let data = try Data(contentsOf: fileURL)
      let probe = try JSONDecoder().decode(VersionProbe.self, from: data)
      guard probe.version == PairedDevicesFile.currentVersion else {
        setAside(reason: "v\(probe.version)")
        return []
      }
      let file = try AtomicFileStore.read(PairedDevicesFile.self, at: fileURL, decoder: Self.decoder)
      return file?.devices ?? []
    } catch {
      logger.error("\(Self.fileName, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
      setAside(reason: "corrupt")
      return []
    }
  }

  /// Moves an unreadable or future-version file out of the way so the next
  /// save does not overwrite it, keeping it for a newer build or a human.
  private func setAside(reason: String) {
    let stamp = Int(now().timeIntervalSince1970)
    let backup = fileURL.deletingLastPathComponent()
      .appendingPathComponent("\(Self.fileName).\(reason).\(stamp).bak", isDirectory: false)
    do {
      try FileManager.default.moveItem(at: fileURL, to: backup)
      logger.error("set aside \(Self.fileName, privacy: .public) as \(backup.lastPathComponent, privacy: .public)")
    } catch {
      logger.error(
        "could not set aside \(Self.fileName, privacy: .public): \(String(describing: error), privacy: .public)")
    }
  }

  private func save() {
    do {
      try AtomicFileStore.write(PairedDevicesFile(devices: devices), to: fileURL, encoder: Self.encoder)
    } catch {
      logger.error("\(Self.fileName, privacy: .public) save failed: \(String(describing: error), privacy: .public)")
    }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder.touchCodeDefault
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
