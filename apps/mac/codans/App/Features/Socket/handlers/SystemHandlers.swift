import AppKit
import Foundation
import CodansCore
import CodansIPC

/// Handlers for the `system.*` method namespace. Construct once and inject
/// into `MethodRouter`.
@MainActor
public final class SystemHandlers {
  public struct Versions: Sendable {
    public let server: String
    public let appBundle: String
    public let protocolMajor: Int
    public let protocolMinor: Int
    public let deprecatedMethods: [String]

    public init(
      server: String,
      appBundle: String,
      protocolMajor: Int = 1,
      protocolMinor: Int = 0,
      deprecatedMethods: [String] = []
    ) {
      self.server = server
      self.appBundle = appBundle
      self.protocolMajor = protocolMajor
      self.protocolMinor = protocolMinor
      self.deprecatedMethods = deprecatedMethods
    }
  }

  private let versions: Versions
  private let startedAt: Date
  private let clock: @Sendable () -> Date
  private let connectionCount: @MainActor () -> Int
  private let quitHandler: @MainActor () -> Void

  public init(
    versions: Versions,
    connectionCount: @escaping @MainActor () -> Int = { 0 },
    quitHandler: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
    clock: @escaping @Sendable () -> Date = Date.init
  ) {
    self.versions = versions
    self.connectionCount = connectionCount
    self.quitHandler = quitHandler
    self.clock = clock
    self.startedAt = clock()
  }

  // MARK: - Handlers

  /// `system.hello` — connection handshake. Returns the server's version
  /// info. Major-version skew surfaces as `.versionMismatch`; clients that
  /// send a malformed `clientVersion` get `.invalidParams`.
  public func hello(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let request: HelloRequest
    do {
      request = try params.decoded(as: HelloRequest.self)
    } catch {
      return .failed(
        .invalidParams(
          message: "system.hello requires clientVersion + clientBinary",
          path: nil
        ))
    }
    if !Self.versionsCompatible(client: request.clientVersion, server: versions.server) {
      return .failed(.versionMismatch(client: request.clientVersion, server: versions.server))
    }
    let response = HelloResponse(
      serverVersion: versions.server,
      appBundleVersion: versions.appBundle,
      protocolMajor: versions.protocolMajor,
      protocolMinor: versions.protocolMinor,
      deprecatedMethods: versions.deprecatedMethods
    )
    do {
      return .unary(try JSONValue.encoded(response))
    } catch {
      return .failed(.internal("failed to encode HelloResponse: \(error)"))
    }
  }

  public func ping(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    return .unary(.object(["pong": .bool(true)]))
  }

  public func version(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    return .unary(
      .object([
        "server": .string(versions.server),
        "appBundle": .string(versions.appBundle),
        "protocolMajor": .int(Int64(versions.protocolMajor)),
        "protocolMinor": .int(Int64(versions.protocolMinor)),
      ]))
  }

  public func status(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    let uptime = clock().timeIntervalSince(startedAt)
    return .unary(
      .object([
        "server": .string(versions.server),
        "uptimeSeconds": .double(uptime),
        "connectedClients": .int(Int64(connectionCount())),
      ]))
  }

  public func quit(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    // Acknowledge first; shutdown on next tick so the caller's response
    // frame actually flushes to the wire before the app tears down.
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 50_000_000)
      quitHandler()
    }
    return .unary(.object(["quitting": .bool(true)]))
  }

  // MARK: - Version check

  /// Major-version compatibility. Either side's version is a dotted string;
  /// we split on `.`, take the leading integer, and require equality.
  /// Bad strings fail open (treated as compatible) rather than killing an
  /// otherwise-working session — a minor-skew warning from `codans` fires
  /// separately on the client.
  static func versionsCompatible(client: String, server: String) -> Bool {
    func major(_ s: String) -> Int? {
      let head = s.split(separator: ".").first.map(String.init) ?? s
      return Int(head)
    }
    guard let c = major(client), let s = major(server) else { return true }
    return c == s
  }
}
