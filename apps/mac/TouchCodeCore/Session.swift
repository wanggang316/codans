import Foundation

/// One running `zmx` daemon belonging to a single `Pane`. Persisted in
/// `sessions.json` so the app can rediscover, ping, and re-attach to live
/// daemons across restarts — independent of the project catalog, since a
/// daemon may outlive any individual app session.
///
/// `zmxVersion` is the daemon binary's reported version at spawn time; on
/// re-attach we refuse to talk to a daemon stamped with a version whose
/// IPC schema we do not understand (the check itself lands later).
public nonisolated struct Session: Codable, Equatable, Sendable {
  public let paneID: PaneID
  public var socketPath: String
  public var pid: Int32
  public var createdAt: Date
  public var lastAttachedAt: Date
  public var command: [String]
  public var cwd: String
  public var zmxVersion: String

  public init(
    paneID: PaneID,
    socketPath: String,
    pid: Int32,
    createdAt: Date,
    lastAttachedAt: Date,
    command: [String],
    cwd: String,
    zmxVersion: String
  ) {
    self.paneID = paneID
    self.socketPath = socketPath
    self.pid = pid
    self.createdAt = createdAt
    self.lastAttachedAt = lastAttachedAt
    self.command = command
    self.cwd = cwd
    self.zmxVersion = zmxVersion
  }
}

/// Versioned on-disk container for the per-pane session catalog. The
/// `sessions` map is keyed by the pane's UUID-string description so the
/// JSON stays diff-stable and human-greppable.
public nonisolated struct SessionCatalog: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public var sessions: [String: Session]

  public init(version: Int = SessionCatalog.currentVersion, sessions: [String: Session] = [:]) {
    self.version = version
    self.sessions = sessions
  }

  public static var empty: SessionCatalog { SessionCatalog() }

  /// Canonical on-disk location: `~/.config/touch-code/sessions.json` —
  /// the same directory `Catalog.defaultURL()` writes to, so all touch-
  /// code state lives under one user-visible root.
  public static func defaultURL(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    home
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("touch-code", isDirectory: true)
      .appendingPathComponent("sessions.json", isDirectory: false)
  }
}
