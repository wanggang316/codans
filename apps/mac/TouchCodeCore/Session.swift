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

/// Per-pane agent state snapshot captured at quit time and replayed at
/// the next launch so the ActiveAgents UI doesn't show "loading" for
/// every surviving agent until the first viewport refresh lands.
///
/// All identifying fields are stored as raw strings rather than enum
/// cases so a future build that adds a new `AgentKind` or
/// `AgentRuntimeState` can decode old catalogs and gracefully drop
/// unknown variants instead of failing the whole load.
public nonisolated struct PersistedAgentRecord: Codable, Equatable, Sendable {
  public let paneID: PaneID
  public let kindRaw: String
  public let stateRaw: String
  /// Process group leader of the agent at capture time. Liveness is
  /// checked at restore via `kill(pid, 0)`: ESRCH → drop the record;
  /// success → seed the registry. `0` means "PID unknown at capture",
  /// which fails the liveness check and is therefore equivalent to a
  /// dead record — the safe default.
  public let pid: Int32
  public let capturedAt: Date

  public init(
    paneID: PaneID,
    kindRaw: String,
    stateRaw: String,
    pid: Int32,
    capturedAt: Date
  ) {
    self.paneID = paneID
    self.kindRaw = kindRaw
    self.stateRaw = stateRaw
    self.pid = pid
    self.capturedAt = capturedAt
  }
}

/// Versioned on-disk container for the per-pane session catalog. The
/// `sessions` map is keyed by the pane's UUID-string description so the
/// JSON stays diff-stable and human-greppable.
public nonisolated struct SessionCatalog: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public var sessions: [String: Session]
  /// Agent state captured at the previous quit's live tier. Optional in
  /// decode so v1 catalogs without this field still load as a catalog
  /// with no agents to restore. Keyed by pane UUID string, mirroring
  /// `sessions`.
  public var agents: [String: PersistedAgentRecord]

  public init(
    version: Int = SessionCatalog.currentVersion,
    sessions: [String: Session] = [:],
    agents: [String: PersistedAgentRecord] = [:]
  ) {
    self.version = version
    self.sessions = sessions
    self.agents = agents
  }

  private enum CodingKeys: String, CodingKey { case version, sessions, agents }

  /// Tolerates a missing `agents` field — a v1 catalog written before
  /// this field existed still decodes to a fresh empty map rather than
  /// failing the whole load. New writes always include the key.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.version = try container.decode(Int.self, forKey: .version)
    self.sessions = try container.decode([String: Session].self, forKey: .sessions)
    self.agents = try container.decodeIfPresent(
      [String: PersistedAgentRecord].self, forKey: .agents
    ) ?? [:]
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(sessions, forKey: .sessions)
    try container.encode(agents, forKey: .agents)
  }

  public static var empty: SessionCatalog { SessionCatalog() }

  /// On-disk location: `<AppDirectories.configDirectory>/sessions.json` —
  /// the same directory `Catalog.defaultURL()` writes to, so all touch-code
  /// state lives under one user-visible root (`-dev` suffixed for Debug
  /// builds; see `AppDirectories`).
  public static func defaultURL(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    AppDirectories.configDirectory(home: home)
      .appendingPathComponent("sessions.json", isDirectory: false)
  }
}
