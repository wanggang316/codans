import Foundation

/// Git facts about the worktree at transition time. Gathered by the app tier
/// (which owns subprocess execution) and handed to the domain store as a
/// value, so the artifact writer never shells out.
public nonisolated struct HandoffRepoState: Equatable, Sendable {
  public var branch: String?
  public var isGit: Bool
  /// Paths from `git status --porcelain`, worktree-relative.
  public var changedFiles: [String]
  public var additions: Int
  public var deletions: Int

  public init(
    branch: String? = nil,
    isGit: Bool = true,
    changedFiles: [String] = [],
    additions: Int = 0,
    deletions: Int = 0
  ) {
    self.branch = branch
    self.isGit = isGit
    self.changedFiles = changedFiles
    self.additions = additions
    self.deletions = deletions
  }

  /// A plain directory with no repository behind it.
  public static let notGit = HandoffRepoState(isGit: false)
}

/// What codans observed about the outgoing pane: which agent ran there, its
/// native session id (when the adapter exposes one), and a screen excerpt
/// captured at transition time. Persisted under `sessions/` so the receiver
/// can look at the last screen the previous agent showed, and reattach to
/// its native session when the CLI supports it.
public nonisolated struct HandoffSessionContext: Equatable, Sendable {
  public var agentKind: AgentKind?
  public var sessionID: String?
  public var paneID: String
  public var paneTitle: String?
  public var screenExcerpt: String?

  public init(
    agentKind: AgentKind? = nil,
    sessionID: String? = nil,
    paneID: String,
    paneTitle: String? = nil,
    screenExcerpt: String? = nil
  ) {
    self.agentKind = agentKind
    self.sessionID = sessionID
    self.paneID = paneID
    self.paneTitle = paneTitle
    self.screenExcerpt = screenExcerpt
  }

  /// The side-effect-free reattach command for the recorded session, when
  /// both the agent and its session id are known. Comes from the agent's
  /// runtime adapter so the handoff artifact and the session-history
  /// popover spell it identically.
  public var resumeCommand: String? {
    guard let agentKind, let sessionID else { return nil }
    return AgentRuntimeAdapters.adapter(for: agentKind).resumeCommand(sessionID: sessionID)
  }
}

/// Wire-friendly summary of a persisted session excerpt.
public nonisolated struct HandoffSessionRecord: Equatable, Sendable, Codable {
  public let agent: String?
  public let sessionID: String?
  public let paneID: String
  public let paneTitle: String?
  /// Path of the excerpt file, relative to the `.codans/` directory.
  public let excerptPath: String
  public let resumeCommand: String?

  public init(
    agent: String?,
    sessionID: String?,
    paneID: String,
    paneTitle: String?,
    excerptPath: String,
    resumeCommand: String?
  ) {
    self.agent = agent
    self.sessionID = sessionID
    self.paneID = paneID
    self.paneTitle = paneTitle
    self.excerptPath = excerptPath
    self.resumeCommand = resumeCommand
  }
}
