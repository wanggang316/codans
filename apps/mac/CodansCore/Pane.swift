import Foundation

public nonisolated struct Pane: Equatable, Sendable, Identifiable {
  public var id: PaneID
  public var workingDirectory: String
  public var initialCommand: String?
  public var labels: Set<String>
  /// Coding-agent identity detected at pane creation / refreshed by the
  /// runtime. Persists across catalog reloads so the AgentState view
  /// can render an agent-specific status before any output is observed.
  public var agentKind: AgentKind?
  /// Opaque per-agent session identifier (e.g. the Claude Code session
  /// UUID) used to correlate the pane with the agent's own session
  /// records. Optional because not every agent exposes one.
  public var agentSessionID: String?
  /// `ScriptDefinition.id` of the run script this pane is dedicated to,
  /// `nil` for ordinary panes. Persisted — unlike the agent binding, the
  /// pane row itself (not its dead pty child) is the identity a relaunch
  /// must recognize, so the next run reuses this pane instead of piling
  /// up a fresh tab per launch.
  public var runScriptID: UUID?
  /// Commands the user has parked on this pane, waiting on the pane going
  /// quiet or on a wall-clock time. Persisted for the same reason as
  /// `runScriptID`: the pane row is the identity the deferred work belongs
  /// to, so a relaunch must restore what the pane still owes.
  public var commandQueue: [QueuedCommand]

  public init(
    id: PaneID = PaneID(),
    workingDirectory: String,
    initialCommand: String? = nil,
    labels: Set<String> = [],
    agentKind: AgentKind? = nil,
    agentSessionID: String? = nil,
    runScriptID: UUID? = nil,
    commandQueue: [QueuedCommand] = []
  ) {
    self.id = id
    self.workingDirectory = workingDirectory
    self.initialCommand = initialCommand
    self.labels = labels
    self.agentKind = agentKind
    self.agentSessionID = agentSessionID
    self.runScriptID = runScriptID
    self.commandQueue = commandQueue
  }
}

extension Pane: Codable {
  private enum CodingKeys: String, CodingKey {
    case id, workingDirectory, labels, agentKind, agentSessionID, runScriptID
    case commandQueue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(PaneID.self, forKey: .id)
    self.workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
    // initialCommand is a one-shot creation-time input replayed by
    // TerminalEngine.ensureSurface. Persisting it would cause the command to
    // re-run on every app launch when the tab is restored. Decode as nil and
    // ignore any legacy value that older builds may have written.
    self.initialCommand = nil
    self.labels = try container.decodeIfPresent(Set<String>.self, forKey: .labels) ?? []
    // agentKind / agentSessionID are optional and absent from pre-T1
    // catalogs; decodeIfPresent + nil default keeps backward compat.
    self.agentKind = try container.decodeIfPresent(AgentKind.self, forKey: .agentKind)
    self.agentSessionID = try container.decodeIfPresent(String.self, forKey: .agentSessionID)
    self.runScriptID = try container.decodeIfPresent(UUID.self, forKey: .runScriptID)
    // Lenient on purpose. A queue written by a build that knows a timing kind
    // this one doesn't would otherwise throw here and take the entire catalog
    // decode down with it. Losing a queue across a downgrade is recoverable;
    // losing every project is not.
    self.commandQueue =
      (try? container.decodeIfPresent([QueuedCommand].self, forKey: .commandQueue)) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(workingDirectory, forKey: .workingDirectory)
    if !labels.isEmpty { try container.encode(labels.sorted(), forKey: .labels) }
    // Forward-compat probe: a pre-T1 catalog that never set these
    // fields must re-encode without introducing the new keys, so we
    // emit them only when non-nil.
    try container.encodeIfPresent(agentKind, forKey: .agentKind)
    try container.encodeIfPresent(agentSessionID, forKey: .agentSessionID)
    try container.encodeIfPresent(runScriptID, forKey: .runScriptID)
    if !commandQueue.isEmpty { try container.encode(commandQueue, forKey: .commandQueue) }
  }
}
