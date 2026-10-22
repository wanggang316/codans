import Foundation

extension IPC {
  /// Version of the wire contract between the `codans` CLI and the app:
  /// method set, parameter and result shapes, and id meanings. Both ends
  /// compile against this constant; the client sends it in `system.hello`,
  /// the server refuses any other value, and the client refuses a server
  /// that reports another one. Raise it on every change an older peer
  /// would misread.
  public static let protocolVersion = 3
}

/// `system.hello` request payload. Pipelined as the first frame of every
/// connection by `codans`. `protocolVersion` is optional on decode so a
/// client that predates it gets a version mismatch, not a params error.
public struct HelloRequest: Codable, Equatable, Sendable {
  public let clientVersion: String
  public let clientBinary: String
  public let protocolVersion: Int?

  public init(
    clientVersion: String,
    clientBinary: String,
    protocolVersion: Int? = IPC.protocolVersion
  ) {
    self.clientVersion = clientVersion
    self.clientBinary = clientBinary
    self.protocolVersion = protocolVersion
  }
}

/// `system.hello` response payload. The server advertises its version, the
/// protocol major / minor, and any methods it considers deprecated.
/// `protocolMajor` carries the server's `IPC.protocolVersion`; a client
/// compiled against another value refuses the connection.
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
