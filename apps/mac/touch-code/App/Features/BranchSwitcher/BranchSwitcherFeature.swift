import ComposableArchitecture
import Foundation
import TouchCodeCore
import os.log

/// Drives the branch popover anchored at `WorktreeHeaderInfoLabel` (T9).
/// Owns the inventory + recent-commits loads, the switch effect, and the
/// HEAD-change reset path. Cross-feature openings (e.g. "View all" → Diff
/// Viewer's History tab) are emitted as `Delegate` actions consumed by
/// `RootFeature` (T10); no direct dependency on DiffFeature.
///
/// Cancellation:
///   - `CancelID.inventory` / `CancelID.commits` — popover-scoped loads.
///     Cancelled on `.worktreeChanged` (so a stale fetch can't paint the
///     new worktree's popover) and on `.branchTapped` (so an open popover
///     load doesn't race with the switch effect that closed the popover).
///   - `CancelID.switchOp` — the `git switch` effect. Cancelled on
///     `.worktreeChanged` so a stale switch can't write a banner into the
///     new worktree.
///   - `CancelID.rename` — the `git branch -m` effect (Phase D). Cancelled
///     on `.worktreeChanged` so a stale rename can't write a banner into
///     the new worktree.
@Reducer
struct BranchSwitcherFeature {
  @ObservableState
  struct State: Equatable {
    var worktreeID: WorktreeID?
    var worktreePath: String?
    var projectID: ProjectID?
    var inventory: BranchInventory?
    var inventoryLoading: Bool = false
    var inventoryError: GitError?
    /// nil = unloaded (so reopening the popover re-fetches);
    /// `[]` = loaded against a 0-commit branch (no re-fetch on reopen);
    /// `[Commit]` = loaded with results.
    var recentCommits: [Commit]?
    var commitsLoading: Bool = false
    var commitsError: GitError?
    var isPopoverOpen: Bool = false
    var isSwitching: Bool = false
    var searchQuery: String = ""
    var switchError: SwitchError?
    /// Maps each "blocked" branch short-name to the OTHER worktree's
    /// folder name that currently has it checked out. A branch is "blocked"
    /// if some other worktree within the same Project (NOT this worktree)
    /// has it as its current `Worktree.branch`. The view greys these rows
    /// and disables click.
    var blockedBranches: [String: String] = [:]
    /// Non-nil while the user is editing the current branch's name in the
    /// row's inline TextField. Holds the original branch name at the time
    /// the user clicked Rename — used to detect "no-op edits" (draft equals
    /// original) so we don't issue an empty `git branch -m`.
    var renamingBranch: String?
    /// The TextField's current contents. Updated by `renameDraftChanged`
    /// from the view's two-way binding. Empty when no rename is in progress.
    var renameDraft: String = ""
    /// True while the `gitService.renameCurrentBranch` effect is in flight.
    /// The TextField becomes read-only (or shows a spinner) while true.
    var renameInFlight: Bool = false
  }

  enum SwitchError: Equatable {
    case message(String)
  }

  enum Action: Equatable {
    case worktreeChanged(
      projectID: ProjectID?,
      worktreeID: WorktreeID?,
      path: String?,
      blockedBranches: [String: String]
    )
    case popoverTapped
    case popoverDismissed
    case searchQueryChanged(String)
    case branchTapped(BranchSwitchTarget)
    case renameButtonTapped(currentBranchName: String)
    case renameDraftChanged(String)
    case renameConfirmed
    case renameCancelled
    case renameSucceeded
    case renameFailed(GitError)
    case viewAllCommitsTapped
    case errorDismissed
    case inventoryLoaded(Result<BranchInventory, GitError>)
    case commitsLoaded(Result<[Commit], GitError>)
    case switchFailed(message: String)
    case headChangedForCurrentWorktree
    case delegate(Delegate)

    enum Delegate: Equatable {
      case openDiffViewerOnHistoryTab(worktreeID: WorktreeID, projectID: ProjectID?)
    }
  }

  /// `nonisolated` because TCA's `.cancellable(id:)` requires
  /// `Hashable & Sendable`. `switchOp` rather than `switch` because the
  /// latter is a reserved keyword and the escaped form (`` `switch` ``)
  /// reads worse at every call site than a one-word substitution.
  nonisolated enum CancelID: Hashable, Sendable {
    case inventory
    case commits
    case switchOp
    case rename
  }

  @Dependency(GitServiceClient.self) private var gitService

  private static let logger = Logger(
    subsystem: "com.touch-code.branch-switcher",
    category: "load"
  )

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .worktreeChanged(let projectID, let worktreeID, let path, let blockedBranches):
        // Replace identifiers; drop every cache so the next popover open
        // re-fetches against the new worktree. Cancel every in-flight
        // effect — a stale switch in particular must not paint a banner
        // on top of the new worktree.
        state.projectID = projectID
        state.worktreeID = worktreeID
        state.worktreePath = path
        state.inventory = nil
        state.inventoryLoading = false
        state.inventoryError = nil
        state.recentCommits = nil
        state.commitsLoading = false
        state.commitsError = nil
        state.isPopoverOpen = false
        state.isSwitching = false
        state.searchQuery = ""
        state.switchError = nil
        // RootFeature computes the blocked map from the catalog (a branch
        // is "blocked" when another worktree in the same Project has it
        // checked out); the reducer just stores it for the view to read.
        state.blockedBranches = worktreeID == nil ? [:] : blockedBranches
        state.renamingBranch = nil
        state.renameDraft = ""
        state.renameInFlight = false
        return .merge(
          .cancel(id: CancelID.inventory),
          .cancel(id: CancelID.commits),
          .cancel(id: CancelID.switchOp),
          .cancel(id: CancelID.rename)
        )

      case .popoverTapped:
        if state.isPopoverOpen {
          // Closing: just flip the flag and reset the query. No effects.
          state.isPopoverOpen = false
          state.searchQuery = ""
          return .none
        }
        state.isPopoverOpen = true
        guard
          state.worktreeID != nil,
          let path = state.worktreePath,
          !path.isEmpty
        else {
          return .none
        }
        var effects: [Effect<Action>] = []
        if state.inventory == nil, !state.inventoryLoading {
          state.inventoryLoading = true
          // Clearing any prior error makes Retry-by-reopen automatic:
          // close + reopen always renders a fresh load, never the stale
          // empty-state-with-error copy.
          state.inventoryError = nil
          effects.append(loadInventory(at: path))
        }
        if state.recentCommits == nil, !state.commitsLoading {
          state.commitsLoading = true
          state.commitsError = nil
          effects.append(loadRecentCommits(at: path))
        }
        return effects.isEmpty ? .none : .merge(effects)

      case .popoverDismissed:
        state.isPopoverOpen = false
        state.searchQuery = ""
        return .none

      case .searchQueryChanged(let query):
        state.searchQuery = query
        return .none

      case .branchTapped(let target):
        // Defensive: if the path is missing we cannot kick the switch
        // effect. The popover should never be open in this state, but the
        // reducer guards the state machine regardless.
        guard let path = state.worktreePath, !path.isEmpty else { return .none }
        state.isSwitching = true
        state.isPopoverOpen = false
        state.switchError = nil
        // Drop any inventory / commit loads kicked by the popover open —
        // the worktree's HEAD is about to move and those results would
        // be stale by the time they land.
        return .merge(
          .cancel(id: CancelID.inventory),
          .cancel(id: CancelID.commits),
          switchTo(target, at: path)
        )

      case .renameButtonTapped(let currentBranchName):
        // Begin inline rename. Pre-fill the draft with the current name and
        // clear any prior switch / rename error so the banner doesn't shadow
        // the new edit.
        guard !state.renameInFlight else { return .none }
        state.renamingBranch = currentBranchName
        state.renameDraft = currentBranchName
        state.switchError = nil
        return .none

      case .renameDraftChanged(let draft):
        state.renameDraft = draft
        return .none

      case .renameConfirmed:
        let trimmed = state.renameDraft.trimmingCharacters(in: .whitespaces)
        // Treat empty / unchanged drafts as a silent cancel — no point
        // round-tripping through git, and "rename to same name" is the
        // natural "I changed my mind" affordance.
        guard let original = state.renamingBranch,
          !trimmed.isEmpty,
          trimmed != original,
          let path = state.worktreePath, !path.isEmpty
        else {
          return .send(.renameCancelled)
        }
        state.renameInFlight = true
        return renameCurrentBranchEffect(to: trimmed, worktreePath: path)

      case .renameCancelled:
        state.renamingBranch = nil
        state.renameDraft = ""
        state.renameInFlight = false
        return .none

      case .renameSucceeded:
        // The WorktreeHeadWatcher will fire `.headChangedForCurrentWorktree`
        // shortly afterwards, which resets the inventory + commits caches.
        // Just clean up the inline-edit fields here.
        state.renamingBranch = nil
        state.renameDraft = ""
        state.renameInFlight = false
        return .none

      case .renameFailed(let error):
        state.renamingBranch = nil
        state.renameDraft = ""
        state.renameInFlight = false
        state.switchError = .message(error.firstLine())
        return .none

      case .viewAllCommitsTapped:
        guard let worktreeID = state.worktreeID else { return .none }
        let projectID = state.projectID
        state.isPopoverOpen = false
        state.searchQuery = ""
        return .send(
          .delegate(.openDiffViewerOnHistoryTab(worktreeID: worktreeID, projectID: projectID))
        )

      case .errorDismissed:
        state.switchError = nil
        return .none

      case .inventoryLoaded(.success(let inventory)):
        state.inventory = inventory
        state.inventoryLoading = false
        state.inventoryError = nil
        return .none

      case .inventoryLoaded(.failure(let error)):
        // Empty-state rendering owns the failure UX; no banner here.
        // The error is captured so the view can render a distinguishing
        // copy ("Couldn't load branches") and so Console gets a signal.
        state.inventory = nil
        state.inventoryLoading = false
        state.inventoryError = error
        Self.logger.error("inventory load failed: \(error.firstLine(), privacy: .public)")
        return .none

      case .commitsLoaded(.success(let commits)):
        state.recentCommits = commits
        state.commitsLoading = false
        state.commitsError = nil
        return .none

      case .commitsLoaded(.failure(let error)):
        state.recentCommits = nil
        state.commitsLoading = false
        state.commitsError = error
        Self.logger.error("commits load failed: \(error.firstLine(), privacy: .public)")
        return .none

      case .switchFailed(let message):
        state.isSwitching = false
        state.switchError = .message(message)
        return .none

      case .headChangedForCurrentWorktree:
        // Forwarded by `RootFeature` from `WorktreeHeadWatcher` only when
        // the watched worktree matches `state.worktreeID`. Reducer trusts
        // the parent's filter and resets the caches so the next popover
        // open re-fetches against the new HEAD.
        state.isSwitching = false
        state.inventory = nil
        state.inventoryError = nil
        state.recentCommits = nil
        state.commitsError = nil
        state.switchError = nil
        // Also clear inline rename state — the branch name has changed
        // out from under us.
        state.renamingBranch = nil
        state.renameDraft = ""
        state.renameInFlight = false
        return .none

      case .delegate:
        return .none
      }
    }
  }

  // MARK: - Effect builders

  private func loadInventory(at worktreePath: String) -> Effect<Action> {
    .run { [gitService] send in
      do {
        let inventory = try await gitService.listAllBranches(URL(fileURLWithPath: worktreePath))
        await send(.inventoryLoaded(.success(inventory)))
      } catch let error as GitError {
        await send(.inventoryLoaded(.failure(error)))
      } catch {
        await send(.inventoryLoaded(.failure(.unparsable(context: "\(error)"))))
      }
    }
    .cancellable(id: CancelID.inventory, cancelInFlight: true)
  }

  private func loadRecentCommits(at worktreePath: String) -> Effect<Action> {
    .run { [gitService] send in
      do {
        let page = try await gitService.log(
          URL(fileURLWithPath: worktreePath),
          LogPage.Cursor(offset: 0, limit: 10)
        )
        await send(.commitsLoaded(.success(page.commits)))
      } catch let error as GitError {
        await send(.commitsLoaded(.failure(error)))
      } catch {
        await send(.commitsLoaded(.failure(.unparsable(context: "\(error)"))))
      }
    }
    .cancellable(id: CancelID.commits, cancelInFlight: true)
  }

  private func switchTo(_ target: BranchSwitchTarget, at worktreePath: String) -> Effect<Action> {
    .run { [gitService] send in
      do {
        try await gitService.switchBranch(target, URL(fileURLWithPath: worktreePath))
        // Success path emits nothing — RootFeature forwards
        // `headChangedForCurrentWorktree` from the head watcher, which
        // clears the spinner and resets the caches.
      } catch let error as GitError {
        await send(.switchFailed(message: error.firstLine()))
      } catch {
        await send(.switchFailed(message: "\(error)"))
      }
    }
    .cancellable(id: CancelID.switchOp, cancelInFlight: true)
  }

  private func renameCurrentBranchEffect(
    to newName: String,
    worktreePath: String
  ) -> Effect<Action> {
    .run { [gitService] send in
      do {
        try await gitService.renameCurrentBranch(newName, URL(fileURLWithPath: worktreePath))
        await send(.renameSucceeded)
      } catch let error as GitError {
        await send(.renameFailed(error))
      } catch {
        await send(.renameFailed(.unparsable(context: "\(error)")))
      }
    }
    .cancellable(id: CancelID.rename, cancelInFlight: true)
  }
}

// MARK: - GitError surface formatting

extension GitError {
  /// First non-empty line of any user-facing stderr the popover would
  /// surface in its banner. For `.exec` this is the first line of the
  /// captured stderr (matches the rest of the app's diff-error UI); every
  /// other case maps to a static, terse human-readable message.
  func firstLine() -> String {
    switch self {
    case .exec(_, let stderr):
      let first = stderr.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
      let trimmed = first.trimmingCharacters(in: .whitespaces)
      return trimmed.isEmpty ? "git failed" : trimmed
    case .notARepo: return "Not a git repository"
    case .gitMissing: return "git not found"
    case .outputTooLarge: return "git output too large"
    case .diffTooLarge: return "diff too large"
    case .timedOut: return "git timed out"
    case .invalidInput(let detail): return detail
    case .unparsable: return "Unrecognised git output"
    case .malformedRemoteURL: return "Malformed remote URL"
    }
  }
}
