import Foundation

/// What a Tab holds: a session identity plus the kind-specific state that
/// recreates it. The `ContentID` keys everything that outlives a layout
/// change — zmx session names, agent state, notifications, command queues,
/// run-script bindings, `CODANS_CONTENT_ID`.
public nonisolated struct ContentSnapshot: Equatable, Sendable, Identifiable {
  public let id: ContentID
  public var state: ContentState

  public init(id: ContentID = ContentID(), state: ContentState) {
    self.id = id
    self.state = state
  }

  public static func terminal(
    id: ContentID = ContentID(),
    workingDirectory: String,
    initialCommand: String? = nil,
    labels: Set<String> = [],
    agentKind: AgentKind? = nil,
    agentSessionID: String? = nil,
    runScriptID: UUID? = nil,
    commandQueue: [QueuedCommand] = []
  ) -> ContentSnapshot {
    ContentSnapshot(
      id: id,
      state: .terminal(
        TerminalContentState(
          workingDirectory: workingDirectory,
          initialCommand: initialCommand,
          labels: labels,
          agentKind: agentKind,
          agentSessionID: agentSessionID,
          runScriptID: runScriptID,
          commandQueue: commandQueue
        )))
  }

  /// The terminal state, or `nil` for another content kind. Writing `nil`
  /// is a no-op: a kind change is a new Content, not an edit.
  public var terminal: TerminalContentState? {
    get { state.terminal }
    set { if let newValue { state = .terminal(newValue) } }
  }
}

extension ContentSnapshot: Codable {
  private enum CodingKeys: String, CodingKey { case id, state }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(ContentID.self, forKey: .id)
    self.state = try container.decode(ContentState.self, forKey: .state)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(state, forKey: .state)
  }
}

/// Kind-keyed content state. The wire shape names the kind and nests the
/// payload under a key of the same name, `{"kind":"terminal","terminal":{…}}`,
/// so a new kind is a new case and a new key — never a schema version.
public nonisolated enum ContentState: Equatable, Sendable {
  case terminal(TerminalContentState)

  public var kind: ContentKind {
    switch self {
    case .terminal: return .terminal
    }
  }

  public var terminal: TerminalContentState? {
    switch self {
    case .terminal(let state): return state
    }
  }
}

public nonisolated enum ContentKind: String, Codable, Sendable, CaseIterable {
  case terminal
}

extension ContentState: Codable {
  private enum CodingKeys: String, CodingKey { case kind, terminal }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(ContentKind.self, forKey: .kind)
    switch kind {
    case .terminal:
      self = .terminal(try container.decode(TerminalContentState.self, forKey: .terminal))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .terminal(let state):
      try container.encode(state, forKey: .terminal)
    }
  }
}

/// State of a terminal Content. Everything here except `initialCommand`
/// is persisted and restored with the catalog.
public nonisolated struct TerminalContentState: Equatable, Sendable {
  public var workingDirectory: String
  /// One-shot command typed into a freshly spawned surface. Live-only: it
  /// is never encoded, so a restored Content does not run it again.
  public var initialCommand: String?
  public var labels: Set<String>
  /// Coding-agent identity detected at creation / refreshed by the
  /// runtime. Persists across catalog reloads so the agent view can render
  /// an agent-specific status before any output is observed.
  public var agentKind: AgentKind?
  /// Opaque per-agent session identifier (e.g. the Claude Code session
  /// UUID) used to correlate the Content with the agent's own session
  /// records. Optional because not every agent exposes one.
  public var agentSessionID: String?
  /// `ScriptDefinition.id` of the run script this Content is dedicated to,
  /// `nil` for an ordinary terminal. Persisted so the next run after a
  /// relaunch reuses this Content instead of opening a fresh Tab.
  public var runScriptID: UUID?
  /// Commands parked on this Content, waiting on it going quiet or on a
  /// wall-clock time. Persisted so a relaunch restores what the Content
  /// still owes.
  public var commandQueue: [QueuedCommand]

  public init(
    workingDirectory: String,
    initialCommand: String? = nil,
    labels: Set<String> = [],
    agentKind: AgentKind? = nil,
    agentSessionID: String? = nil,
    runScriptID: UUID? = nil,
    commandQueue: [QueuedCommand] = []
  ) {
    self.workingDirectory = workingDirectory
    self.initialCommand = initialCommand
    self.labels = labels
    self.agentKind = agentKind
    self.agentSessionID = agentSessionID
    self.runScriptID = runScriptID
    self.commandQueue = commandQueue
  }

  /// Per-Content notification mute — membership of `InboxLabels.muted` in
  /// `labels`. Spelled once here because the detector's drop check and the
  /// Tab menus all ask it.
  public var isNotificationsMuted: Bool {
    labels.contains(InboxLabels.muted)
  }
}

extension TerminalContentState: Codable {
  private enum CodingKeys: String, CodingKey {
    case workingDirectory, labels, agentKind, agentSessionID, runScriptID, commandQueue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
    self.initialCommand = nil
    self.labels = try container.decodeIfPresent(Set<String>.self, forKey: .labels) ?? []
    self.agentKind = try container.decodeIfPresent(AgentKind.self, forKey: .agentKind)
    self.agentSessionID = try container.decodeIfPresent(String.self, forKey: .agentSessionID)
    self.runScriptID = try container.decodeIfPresent(UUID.self, forKey: .runScriptID)
    // Lenient on purpose. A queue written by a build that knows a timing kind
    // this one doesn't would otherwise throw here and drop the whole Tab.
    // Losing a queue across a downgrade is recoverable; losing a session is
    // not.
    self.commandQueue =
      (try? container.decodeIfPresent([QueuedCommand].self, forKey: .commandQueue)) ?? []
  }

  /// Omit-when-default: an unset field writes no key, so a catalog that
  /// never touched it round-trips byte-identically.
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(workingDirectory, forKey: .workingDirectory)
    if !labels.isEmpty { try container.encode(labels.sorted(), forKey: .labels) }
    try container.encodeIfPresent(agentKind, forKey: .agentKind)
    try container.encodeIfPresent(agentSessionID, forKey: .agentSessionID)
    try container.encodeIfPresent(runScriptID, forKey: .runScriptID)
    if !commandQueue.isEmpty { try container.encode(commandQueue, forKey: .commandQueue) }
  }
}
