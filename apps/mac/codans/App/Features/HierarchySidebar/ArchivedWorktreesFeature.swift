import ComposableArchitecture
import Foundation
import CodansCore

/// Reducer backing the "Archived Worktrees" sheet opened from the
/// Project `⋯` menu. The view reads archived worktrees live from
/// `HierarchyManager.catalog` on each render; this reducer owns only
/// transient UX state (the in-sheet error banner + a pending-removal
/// payload awaiting confirmation). Mirrors the sidebar's
/// single-confirmation flow — see HierarchySidebarFeature.
@Reducer
struct ArchivedWorktreesFeature {
  @ObservableState
  struct State: Equatable {
    let projectID: ProjectID
    var banner: String?
    /// Payload for the destructive-remove confirmation dialog. Non-nil
    /// → dialog visible.
    var pendingRemoval: PendingRemoval?
  }

  struct PendingRemoval: Equatable {
    var worktreeID: WorktreeID
    var worktreeName: String
  }

  enum Action: Equatable {
    case unarchiveTapped(WorktreeID)
    case removeTapped(WorktreeID, displayName: String)
    case removeConfirmed
    case removeCancelled
    case removeFinished(worktreeID: WorktreeID, error: String?)
    case dismissBanner
    case closeButtonTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismissed
    }
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .unarchiveTapped(let worktreeID):
        do {
          try hierarchyClient.setWorktreeArchived(worktreeID, false)
          state.banner = nil
        } catch {
          state.banner = "Failed to unarchive: \(error.localizedDescription)"
        }
        return .none

      case .removeTapped(let worktreeID, let displayName):
        state.pendingRemoval = PendingRemoval(
          worktreeID: worktreeID, worktreeName: displayName
        )
        state.banner = nil
        return .none

      case .removeConfirmed:
        guard let pending = state.pendingRemoval else { return .none }
        let projectID = state.projectID
        let client = hierarchyClient
        let worktreeID = pending.worktreeID
        state.pendingRemoval = nil
        return .run { send in
          do {
            try await client.removeWorktreeWithGit(worktreeID, projectID)
            await send(.removeFinished(worktreeID: worktreeID, error: nil))
          } catch let gitError as GitWorktreeError {
            await send(.removeFinished(worktreeID: worktreeID, error: humanReadable(gitError)))
          } catch {
            await send(.removeFinished(worktreeID: worktreeID, error: error.localizedDescription))
          }
        }

      case .removeCancelled:
        state.pendingRemoval = nil
        return .none

      case .removeFinished(_, let error):
        state.banner = error
        return .none

      case .dismissBanner:
        state.banner = nil
        return .none

      case .closeButtonTapped:
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }
}
