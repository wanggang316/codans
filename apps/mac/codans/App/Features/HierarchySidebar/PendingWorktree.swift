import CodansCore
import Foundation

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
  /// SSH host for a Server project's creation, `nil` for local. Non-nil
  /// routes the run to `git worktree add` over SSH instead of the local
  /// `wt sw` stream. Stamped at sheet construction (the sheet knows its
  /// project), so the run needs no catalog lookup.
  var remoteHost: RemoteHost?
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

  /// `true` while the creation is still streaming (either leg). The row's
  /// decorative shimmer and spinner key on this; it settles to `false` on
  /// failure (and the row leaves the pending list entirely on success).
  var isRunning: Bool {
    if case .running = status { return true }
    return false
  }

  /// Stable, machine-readable signal for whether the worktree NAME is still
  /// in-flight, exposed as the name's accessibility value so the lifecycle
  /// state is probeable without reading the (decorative) shimmer animation.
  /// The vocabulary is a fixed contract that later validation keys on —
  /// DO NOT rename these strings:
  ///   - `in-progress` — creation is still streaming (running, either leg)
  ///   - `settled`     — creation has stopped progressing (failed; success
  ///                     removes the row from the pending list, so the only
  ///                     settled state a row reports is `.failed`)
  /// Complements the per-leg stage value on the row (`creating` /
  /// `setupScript` / `failed`); see `PendingWorktreeRow.stageAccessibilityValue`
  /// and `pending-phase-lifecycle`.
  var nameProgressAccessibilityValue: String {
    isRunning ? "in-progress" : "settled"
  }
}
