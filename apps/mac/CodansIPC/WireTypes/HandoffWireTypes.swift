import CodansCore
import Foundation

extension IPC {
  public enum HandoffAction: String, Codable, Equatable, Sendable {
    case save
    case to
  }

  /// Params for `handoff.save` / `handoff.to`. The CLI resolves the source
  /// pane before sending (`current` → the calling pane), so the server only
  /// ever sees a concrete `paneID`.
  ///
  /// `brief` and `contextOnly` are the two ways to answer "where does the
  /// briefing come from"; the handler rejects a request that gives neither
  /// with guidance and zero side effects.
  public struct HandoffRequest: Codable, Equatable, Sendable {
    public let action: HandoffAction
    public let paneID: PaneID
    /// Receiving agent token for `to` (raw value, executable, or display
    /// name). Ignored by `save`.
    public let receiver: String?
    /// Optional profile (id or name) to launch the receiver with. Must
    /// belong to `receiver`'s agent.
    public let profile: String?
    public let brief: String?
    public let contextOnly: Bool
    public let note: String?
    /// `false` archives and saves but does not start the receiver.
    public let launch: Bool
    /// One-shot id from an app-injected request; ordinary CLI use omits it.
    public let requestID: UUID?
    /// Where the receiver opens: `.newTab` (the default when nil) or `.split`
    /// beside the source pane. `.focused` is refused by the server.
    public let target: ScriptTarget?
    /// Consumed only with `.split`; nil means right.
    public let direction: ScriptSplitDirection?

    public init(
      action: HandoffAction,
      paneID: PaneID,
      receiver: String? = nil,
      profile: String? = nil,
      brief: String? = nil,
      contextOnly: Bool = false,
      note: String? = nil,
      launch: Bool = true,
      requestID: UUID? = nil,
      target: ScriptTarget? = nil,
      direction: ScriptSplitDirection? = nil
    ) {
      self.action = action
      self.paneID = paneID
      self.receiver = receiver
      self.profile = profile
      self.brief = brief
      self.contextOnly = contextOnly
      self.note = note
      self.launch = launch
      self.requestID = requestID
      self.target = target
      self.direction = direction
    }
  }

  /// The pane the receiving agent was launched into.
  public struct HandoffLaunchedPane: Codable, Equatable, Sendable {
    public let projectID: ProjectID
    public let worktreeID: WorktreeID
    public let tabID: TabID
    public let paneID: PaneID
    public let profileName: String

    public init(
      projectID: ProjectID,
      worktreeID: WorktreeID,
      tabID: TabID,
      paneID: PaneID,
      profileName: String
    ) {
      self.projectID = projectID
      self.worktreeID = worktreeID
      self.tabID = tabID
      self.paneID = paneID
      self.profileName = profileName
    }
  }

  public struct HandoffResponse: Codable, Equatable, Sendable {
    public let action: HandoffAction
    /// Absolute path of `current.md`, whether or not it exists after this call.
    public let artifactPath: String
    public let outgoingAgent: String?
    public let receiver: String?
    public let branch: String?
    public let changedFileCount: Int
    /// Archived snapshot of the previous round, relative to `.codans/`.
    public let archivedPath: String?
    public let sessionExcerptPath: String?
    /// `inline` or `none`.
    public let briefing: String
    /// A fresh `current.md` exists for the receiver.
    public let hasBriefing: Bool
    public let launchedPane: HandoffLaunchedPane?

    public init(
      action: HandoffAction,
      artifactPath: String,
      outgoingAgent: String?,
      receiver: String?,
      branch: String?,
      changedFileCount: Int,
      archivedPath: String?,
      sessionExcerptPath: String?,
      briefing: String,
      hasBriefing: Bool,
      launchedPane: HandoffLaunchedPane?
    ) {
      self.action = action
      self.artifactPath = artifactPath
      self.outgoingAgent = outgoingAgent
      self.receiver = receiver
      self.branch = branch
      self.changedFileCount = changedFileCount
      self.archivedPath = archivedPath
      self.sessionExcerptPath = sessionExcerptPath
      self.briefing = briefing
      self.hasBriefing = hasBriefing
      self.launchedPane = launchedPane
    }
  }
}
