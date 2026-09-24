import Foundation
import Network

/// Bonjour vocabulary of the LAN gateway, shared by the Mac advertiser and
/// the iOS browser so the two cannot drift.
public enum RemoteBonjour {
  /// DNS-SD service type. iOS must list the same string under
  /// `NSBonjourServices`.
  public static let serviceType = "_codans._tcp"

  /// TXT key carrying `BuildChannel.slug` (`codans` / `codans-dev`). A phone
  /// only lists gateways whose channel matches its pairing, so a Debug
  /// build never answers a phone paired with the Release build.
  public static let channelKey = "channel"

  /// TXT key carrying the IPC protocol major version.
  public static let protocolMajorKey = "v"

  public static func txtRecord(channel: String, protocolMajor: Int) -> NWTXTRecord {
    var record = NWTXTRecord()
    record[channelKey] = channel
    record[protocolMajorKey] = String(protocolMajor)
    return record
  }

  /// The channel a discovered service advertises, if any.
  public static func channel(in record: NWTXTRecord) -> String? {
    record[channelKey]
  }

  /// The protocol major a discovered service advertises, if parseable.
  public static func protocolMajor(in record: NWTXTRecord) -> Int? {
    record[protocolMajorKey].flatMap(Int.init)
  }

  /// Advertised service name. Release uses the host name as-is; any other
  /// channel appends its slug so both builds on one Mac are distinguishable
  /// in a Bonjour browser.
  public static func serviceName(hostName: String, channel: String, releaseChannel: String = "codans") -> String {
    channel == releaseChannel ? hostName : "\(hostName) (\(channel))"
  }
}
