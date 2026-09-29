import CodansCore
import Foundation

/// Every status-bar activity id the app emits. One registry so two features
/// can never collide on a domain, and so a canceller can recognise its own ids.
extension StatusActivityID {
  /// One gh mutation (merge / close / mark ready / rerun) per worktree —
  /// `GitHubFeature.mutating` already serialises them.
  static func pullRequestMutation(_ worktreeID: WorktreeID) -> Self {
    Self("pr.mutation", worktreeID.raw.uuidString)
  }

  /// Opening a worktree in an external editor. Opens are not tracked per
  /// request, so a second open replaces the first.
  static let editorOpen = Self("editor.open")

  /// Manual reconcile of every project, or of the selected one.
  static let projectRefresh = Self("project.refresh")

  /// A panel-issued hand-off waiting for the source agent's briefing.
  /// Context-only hand-offs carry no request id and are never begun.
  static func handoff(_ requestID: UUID?) -> Self {
    Self(handoffDomain, requestID?.uuidString)
  }

  /// The hand-off request an id was built from, nil for any other id.
  var handoffRequestID: UUID? {
    guard domain == Self.handoffDomain, let key else { return nil }
    return UUID(uuidString: key)
  }

  static func workspaceRemoval(_ projectID: ProjectID) -> Self {
    Self("workspace.remove", projectID.raw.uuidString)
  }

  static func workspaceMemberRemoval(_ worktreeID: WorktreeID) -> Self {
    Self("workspace.member.remove", worktreeID.raw.uuidString)
  }

  private static let handoffDomain = "handoff"
}
