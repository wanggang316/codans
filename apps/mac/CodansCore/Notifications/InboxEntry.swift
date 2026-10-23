import Foundation

/// One inbox entry. Produced by the runtime-event detector, persisted to
/// `~/.codans/state/notifications.json`, surfaced through hierarchical
/// roll-up indicators, the status-bar bell popover, and (when the user is
/// not focused on the source pane) macOS banners.
///
/// Named `InboxEntry` rather than `Notification` to avoid the value-type
/// clash with `Foundation.Notification`; consumers `import Foundation`
/// nearly everywhere, and disambiguating with module-qualified names at
/// every call site is more friction than the slightly longer type name.
///
/// `source` captures the originating Project, Worktree, and Content at
/// creation time. The Pane and Tab of a Content are resolved against the
/// current `Catalog` when navigating, so a Tab that moved is still found;
/// a deleted node falls back to the deepest still-existing ancestor.
///
/// Reserved string keys for `TerminalContentState.labels` that drive this
/// system are collected in `InboxLabels` (just below) so the detector and
/// the Tab menus agree on one constant.
public nonisolated enum InboxLabels {
  /// Per-Content mute. When the Content's `labels` contains this string,
  /// the detector drops the event before any banner / store mutation.
  public static let muted: String = "notifications:muted"
}

public nonisolated struct InboxEntry: Equatable, Codable, Sendable, Identifiable {
  public let id: NotificationID
  public let kind: Kind
  public let title: String
  public let body: String
  public let createdAt: Date
  public var readAt: Date?
  public let source: SourcePath

  public init(
    id: NotificationID = NotificationID(),
    kind: Kind,
    title: String,
    body: String,
    createdAt: Date = Date(),
    readAt: Date? = nil,
    source: SourcePath
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.body = body
    self.createdAt = createdAt
    self.readAt = readAt
    self.source = source
  }

  public var isUnread: Bool { readAt == nil }

  public enum Kind: String, Codable, Sendable, CaseIterable, Equatable {
    /// A pane is blocked on a user prompt — agent permission line, shell
    /// `read -p`, terminal bell. Higher visual priority than `taskFinished`.
    case waitingForInput
    /// A long-running task has finished or the pane has gone idle. Subsumes
    /// clean exit, non-zero exit, crash, and post-busy idle timeout.
    case taskFinished
  }

  public struct SourcePath: Equatable, Sendable {
    public let projectID: ProjectID
    public let worktreeID: WorktreeID
    public let contentID: ContentID

    public init(projectID: ProjectID, worktreeID: WorktreeID, contentID: ContentID) {
      self.projectID = projectID
      self.worktreeID = worktreeID
      self.contentID = contentID
    }
  }
}

extension InboxEntry.SourcePath: Codable {
  private enum CodingKeys: String, CodingKey {
    case projectID, worktreeID, contentID
    /// Rows written before the content vocabulary keyed the session as
    /// `paneID`; the UUID is the same identity.
    case legacyPaneID = "paneID"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.projectID = try container.decode(ProjectID.self, forKey: .projectID)
    self.worktreeID = try container.decode(WorktreeID.self, forKey: .worktreeID)
    if let contentID = try container.decodeIfPresent(ContentID.self, forKey: .contentID) {
      self.contentID = contentID
    } else {
      let legacy = try container.decode(PaneID.self, forKey: .legacyPaneID)
      self.contentID = ContentID(raw: legacy.raw)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(projectID, forKey: .projectID)
    try container.encode(worktreeID, forKey: .worktreeID)
    try container.encode(contentID, forKey: .contentID)
  }
}
