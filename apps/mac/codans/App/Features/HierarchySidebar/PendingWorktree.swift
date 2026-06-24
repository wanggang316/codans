import CodansCore
import Foundation

/// In-memory placeholder for a worktree whose `wt sw` is still streaming.
/// Lives on `HierarchySidebarFeature.State.pendingWorktrees`. Distinct
/// from the persistent `Worktree` (catalog) — pending rows have no on-disk
/// presence in catalog.json, no `WorktreeID`, no Tab/Pane attachment, and
/// vanish on app restart. See `docs/design-docs/worktree-sidebar-ordering.md`
/// §pending 段 for the full contract.
nonisolated struct PendingWorktreeID: Hashable, Sendable {
  let raw: UUID
  init() { raw = UUID() }
  init(_ raw: UUID) { self.raw = raw }
}

struct PendingWorktree: Equatable, Identifiable {
  let id: PendingWorktreeID
  let projectID: ProjectID
  /// Mutable so `beginPendingWorktreeCreation` can stash the project's setup
  /// command into `spec.setupCommand` just before streaming (the sheet
  /// builds the spec without it). Otherwise stable for the row's lifetime.
  var spec: CreateWorktreeSpec
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

  /// Which leg of `createWorktreeStream` this pending row is currently in.
  /// Starts at `.creatingWorktree` (the `wt sw` / git-add leg) and flips to
  /// `.runningSetupScript` when the stream emits `.setupPhaseBegan` (only
  /// happens when a non-empty setup command is present). Drives the row's
  /// accessibility stage value so later validation can observe the
  /// creating → setupScript transition. See `pending-phase-lifecycle`.
  var phase: CreationPhase = .creatingWorktree
  /// The on-disk path of the worktree once `git worktree add` has finished
  /// (carried by `.setupPhaseBegan`). Nil until the worktree materializes.
  /// Stashed here so a future cancel can materialize-on-cancel; this
  /// feature only sets it, it does not yet act on it.
  var materializedPath: URL?

  /// Soft cap on the streaming tail. Five lines is enough to read git's
  /// "Resolving deltas: 100% (842/842), done." without the loading
  /// view's footprint creeping past a single screen.
  static let progressLineWindow = 5

  enum Status: Equatable {
    case running
    case failed(GitWorktreeError)
  }
}
