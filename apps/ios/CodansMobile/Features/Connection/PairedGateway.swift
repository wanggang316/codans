import CodansRemote
import Foundation

/// A Mac this phone has paired with, minus its key. The key lives only in
/// the Keychain (`PairingStore`); this record is what the UI lists and what
/// discovery matches against.
nonisolated struct PairedGateway: Codable, Equatable, Hashable, Identifiable, Sendable {
  /// The device ID the Mac issued for this phone. Unique per pairing, so it
  /// doubles as the record's identity.
  let deviceID: UUID
  /// Bonjour service name of the gateway at pairing time.
  let serviceName: String
  /// `BuildChannel.slug` of the Mac build; discovery ignores other channels.
  let channel: String
  let pskIdentity: String
  let pairedAt: Date

  var id: UUID { deviceID }

  init(deviceID: UUID, serviceName: String, channel: String, pskIdentity: String, pairedAt: Date) {
    self.deviceID = deviceID
    self.serviceName = serviceName
    self.channel = channel
    self.pskIdentity = pskIdentity
    self.pairedAt = pairedAt
  }

  init(payload: PairingPayload, pairedAt: Date) {
    self.init(
      deviceID: payload.deviceID,
      serviceName: payload.serviceName,
      channel: payload.channel,
      pskIdentity: payload.pskIdentity,
      pairedAt: pairedAt
    )
  }

  /// Name shown in the UI: the Bonjour name without the channel suffix a
  /// development build appends.
  var displayName: String {
    let suffix = " (\(channel))"
    return serviceName.hasSuffix(suffix) ? String(serviceName.dropLast(suffix.count)) : serviceName
  }
}
