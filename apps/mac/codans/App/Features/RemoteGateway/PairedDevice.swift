import CodansIPC
import Foundation

/// A phone or tablet allowed to reach the LAN gateway. Metadata only: the
/// device's pre-shared key lives in the Keychain, never in this record.
struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
  enum State: String, Codable, Sendable {
    /// Pairing code issued, no successful handshake yet. Expires after
    /// `PairedDeviceStore.pendingLifetime` so an abandoned code stops
    /// being a credential.
    case pending
    /// Has completed at least one handshake.
    case active
  }

  /// Also the TLS-PSK identity the device offers.
  let id: UUID
  var name: String
  var permission: IPC.RemotePermission
  var state: State
  let createdAt: Date
  var lastSeenAt: Date?

  var pskIdentity: String { id.uuidString }
}

/// On-disk shape of `remote-devices.json`.
struct PairedDevicesFile: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int
  var devices: [PairedDevice]

  init(version: Int = PairedDevicesFile.currentVersion, devices: [PairedDevice]) {
    self.version = version
    self.devices = devices
  }
}
