import Foundation

/// `system.hello` request payload. Pipelined as the first frame of every
/// connection by `codans` (exec-plan 0003 DEC-4).
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

  public init(
    serverVersion: String,
    appBundleVersion: String,
    protocolMajor: Int,
    protocolMinor: Int,
    deprecatedMethods: [String] = []
  ) {
    self.serverVersion = serverVersion
    self.appBundleVersion = appBundleVersion
    self.protocolMajor = protocolMajor
    self.protocolMinor = protocolMinor
    self.deprecatedMethods = deprecatedMethods
  }
}
