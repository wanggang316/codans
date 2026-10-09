import Foundation

/// `system.hello` request payload. Pipelined as the first frame of every
/// connection by `codans`.
public struct HelloRequest: Codable, Equatable, Sendable {
  public let clientVersion: String
  public let clientBinary: String

  public init(clientVersion: String, clientBinary: String) {
    self.clientVersion = clientVersion
    self.clientBinary = clientBinary
  }
}

/// `system.hello` response payload. The server advertises its version, the
/// protocol major / minor, and any methods it considers deprecated. A major
/// version mismatch surfaces as `IPCError.versionMismatch`.
public struct HelloResponse: Codable, Equatable, Sendable {
  public let serverVersion: String
  public let appBundleVersion: String
  public let protocolMajor: Int
  public let protocolMinor: Int
  public let deprecatedMethods: [String]
  /// The permission the calling device holds, present only for callers on
  /// the LAN gateway. Lets a phone hide input controls it may not use; it
  /// reflects the moment of the handshake, and the router stays the
  /// authority for every later call.
  public let remotePermission: IPC.RemotePermission?
  /// Where a gateway caller can reach this Mac from outside the LAN, while
  /// the user allows it; nil otherwise and for local callers. A phone
  /// paired before the relay existed learns it here.
  public let relay: RemoteRelayCoordinates?

  public init(
    serverVersion: String,
    appBundleVersion: String,
    protocolMajor: Int,
    protocolMinor: Int,
    deprecatedMethods: [String] = [],
    remotePermission: IPC.RemotePermission? = nil,
    relay: RemoteRelayCoordinates? = nil
  ) {
    self.serverVersion = serverVersion
    self.appBundleVersion = appBundleVersion
    self.protocolMajor = protocolMajor
    self.protocolMinor = protocolMinor
    self.deprecatedMethods = deprecatedMethods
    self.remotePermission = remotePermission
    self.relay = relay
  }
}

/// A Mac's address on the relay: the relay's base URL and the Mac's ID
/// there. Carries no secret; a phone also needs its pairing key.
public struct RemoteRelayCoordinates: Codable, Equatable, Hashable, Sendable {
  public let url: String
  public let macID: String

  public init(url: String, macID: String) {
    self.url = url
    self.macID = macID
  }
}
