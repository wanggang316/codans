import Foundation

/// One inbox entry. Produced by the runtime-event detector, persisted to
/// `~/.config/codans/notifications.json`, surfaced through hierarchical
/// roll-up indicators, the status-bar bell popover, and (when the user is
/// not focused on the source pane) macOS banners.
///
/// Named `InboxEntry` rather than `Notification` to avoid the value-type
/// clash with `Foundation.Notification`; consumers `import Foundation`
/// nearly everywhere, and disambiguating with module-qualified names at
/// every call site is more friction than the slightly longer type name.
///
/// `source` captures the originating hierarchy path verbatim at creation
/// time. Hierarchy nodes can be deleted afterwards; navigation re-resolves
/// the path against the current `Catalog` and falls back to the deepest
/// still-existing ancestor.
///
/// Reserved string keys for `Pane.labels` that drive this system are
/// collected in `InboxLabels` (just below) so the detector and any
/// future per-pane toggle UI agree on one constant.
public nonisolated enum InboxLabels {
  /// Per-pane mute. When the pane's `labels` contains this string, the
  /// detector drops the event before any banner / store mutation.
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

  public struct SourcePath: Equatable, Codable, Sendable {
    public let projectID: ProjectID
    public let worktreeID: WorktreeID
    public let tabID: TabID
    public let paneID: PaneID

    public init(projectID: ProjectID, worktreeID: WorktreeID, tabID: TabID, paneID: PaneID) {
      self.projectID = projectID
      self.worktreeID = worktreeID
      self.tabID = tabID
      self.paneID = paneID
    }
  }
}
