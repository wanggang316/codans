import Foundation

/// The one transition core every handoff entry point drives — the CLI
/// handler for agent-initiated handoffs and the HUD's context-only fallback.
/// A transition always runs the same sequence:
///
///   validate briefing → archive outgoing state → install fresh briefing
///   (or remove the stale one) → refresh generated context → [launch] → log
///
/// Launching the receiving agent stays with the caller (it needs the pane
/// runtime); every persisted artifact and log line lives here so the two
/// entry points cannot drift.
public nonisolated struct HandoffCoordinator: Sendable {
  public let store: HandoffStore

  public init(store: HandoffStore) {
    self.store = store
  }

  /// Everything a transition persists before the receiver launches.
  public struct Transition: Equatable, Sendable {
    public let briefing: HandoffBriefingOutcome
    /// Archived snapshot of the previous round, relative to `.codans/`.
    public let archivedPath: String?
    public let session: HandoffSessionRecord?
    public let repo: HandoffRepoState
    /// `current.md` exists for the receiver to read.
    public var hasBriefing: Bool { briefing.wroteBriefing }
  }

  /// What `save` persisted.
  public struct Checkpoint: Equatable, Sendable {
    public let briefing: HandoffBriefingOutcome
    public let session: HandoffSessionRecord?
    public let repo: HandoffRepoState
  }

  /// How the receiving agent was (or was not) started, for the log line.
  public enum LaunchDisposition: Equatable, Sendable {
    /// Launched into a resolved pane.
    case pane(String)
    /// `--no-launch`.
    case skipped
    /// The launch attempt produced no pane.
    case failed
  }

  /// `handoff to`, up to the destination launch. The archive precedes every
  /// rewrite, so the outgoing round survives in `archive/` no matter what
  /// the new briefing contains.
  public func transition(
    outgoing: AgentKind?,
    to receiver: AgentKind,
    session: HandoffSessionContext?,
    repo: HandoffRepoState,
    briefing: HandoffPreparedBriefing,
    now: Date
  ) throws -> Transition {
    let from = outgoing?.rawValue ?? "agent"
    let archivedPath = try store.archiveCurrent(from: from, to: receiver.rawValue, now: now)
    if let artifact = briefing.artifact {
      try store.writeBriefing(artifact, archivingPrevious: false, now: now)
    } else {
      try store.removeCurrentBriefing()
    }
    let record = try session.map { try store.writeSession($0, now: now) }
    try store.writeContext(outgoingAgent: outgoing, repo: repo, session: record, now: now)
    return Transition(
      briefing: briefing.outcome,
      archivedPath: archivedPath,
      session: record,
      repo: repo
    )
  }

  /// `handoff save`: a deferred-handoff checkpoint. Installs a fresh
  /// briefing when one was supplied (archiving the replaced one) and
  /// refreshes generated context. Unlike a transition it never removes an
  /// earlier briefing — with no receiver, the last validated one stays.
  public func checkpoint(
    outgoing: AgentKind?,
    session: HandoffSessionContext?,
    repo: HandoffRepoState,
    briefing: HandoffPreparedBriefing,
    note: String?,
    now: Date
  ) throws -> Checkpoint {
    if let artifact = briefing.artifact {
      try store.writeBriefing(artifact, archivingPrevious: true, now: now)
    }
    let record = try session.map { try store.writeSession($0, now: now) }
    try store.writeContext(outgoingAgent: outgoing, repo: repo, session: record, now: now)
    var line =
      "save  agent=\(outgoing?.rawValue ?? "unknown")  changed=\(repo.changedFiles.count)"
      + "  briefing=\(briefing.outcome.rawValue)"
    line += Self.noteSuffix(note)
    try store.appendLog(line, now: now)
    return Checkpoint(briefing: briefing.outcome, session: record, repo: repo)
  }

  /// Appends the single transition line every entry point shares.
  public func logTransition(
    from: AgentKind?,
    to receiver: AgentKind,
    disposition: LaunchDisposition,
    briefing: HandoffBriefingOutcome,
    archivedPath: String? = nil,
    note: String? = nil,
    source: String? = nil,
    now: Date
  ) throws {
    try store.appendLog(
      Self.transitionLogLine(
        from: from,
        to: receiver,
        disposition: disposition,
        briefing: briefing,
        archivedPath: archivedPath,
        note: note,
        source: source
      ),
      now: now
    )
  }

  static func transitionLogLine(
    from: AgentKind?,
    to receiver: AgentKind,
    disposition: LaunchDisposition,
    briefing: HandoffBriefingOutcome,
    archivedPath: String?,
    note: String?,
    source: String?
  ) -> String {
    let launchPart =
      switch disposition {
      case .pane(let paneID): "  pane=\(paneID)"
      case .skipped: "  (no launch)"
      case .failed: "  launch=failed"
      }
    var line = "\(from?.rawValue ?? "agent") -> \(receiver.rawValue)\(launchPart)"
    line += "  briefing=\(briefing.rawValue)"
    if case .failed = disposition, let archivedPath {
      line += "  archive=\(archivedPath)"
    }
    if let source {
      line += "  source=\(source)"
    }
    line += noteSuffix(note)
    return line
  }

  private static func noteSuffix(_ note: String?) -> String {
    guard let note else { return "" }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    return "  note=\"\(trimmed.replacingOccurrences(of: "\n", with: " "))\""
  }
}
