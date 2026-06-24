import Foundation
import CodansCore

/// In-memory placeholder for a worktree whose `wt sw` is still streaming.
/// Lives on `HierarchySidebarFeature.State.pendingWorktrees`. Distinct
/// from the persistent `Worktree` (catalog) — pending rows have no on-disk
/// presence in catalog.json, no `WorktreeID`, no Tab/Pane attachment, and
/// vanish on app restart.
nonisolated struct PendingWorktreeID: Hashable, Sendable {
  let raw: UUID
  init() { raw = UUID() }
  init(_ raw: UUID) { self.raw = raw }
}

struct PendingWorktree: Equatable, Identifiable {
  let id: PendingWorktreeID
  let projectID: ProjectID
  let spec: CreateWorktreeSpec
  let displayName: String
  var status: Status
  var lastProgressLine: String?
  /// Last `Self.progressLineWindow` lines of `wt sw` stdout/stderr, in
  /// arrival order. Drives the WorktreeLoadingView's streaming-output
  /// tail in the detail pane; the sidebar row keeps reading
  /// `lastProgressLine` so the visual contract there is unchanged.
  /// Capped on insert in `HierarchySidebarFeature.pendingWorktreeProgress`.
  var progressLines: [String] = []
  let startedAt: Date

  /// Soft cap on the streaming tail. Five lines is enough to read git's
  /// "Resolving deltas: 100% (842/842), done." without the loading
  /// view's footprint creeping past a single screen.
  static let progressLineWindow = 5

  enum Status: Equatable {
    case running
    case failed(GitWorktreeError)
  }
}
