import CodansCore
import ComposableArchitecture
import Foundation

/// Turns child-feature actions into status-bar activities and toasts — the one
/// place a reader looks to learn what the status bar reports and why.
///
/// Child features never reference `StatusBarFeature`; they expose their
/// outcomes as ordinary actions and this reducer maps them. Effects that
/// `RootFeature` itself owns (run script, hand-off, …) send `.statusBar(...)`
/// directly instead.
///
/// Stacked in `RootFeature.body` BEFORE the child scopes, so a request case
/// sees the child's state as it was when the request arrived. That is how a
/// begin is skipped when the child is about to reject the request (a gh
/// mutation already running, a removal with no pending confirmation) and
/// would never send the completion that ends the activity.
struct StatusBarRootBindings: Reducer {
  var body: some Reducer<RootFeature.State, RootFeature.Action> {
    Reduce { state, action in
      switch action {
      case .gitHub(let action):
        return gitHub(action, state: state)
      case .editor(let action):
        return editor(action, state: state)
      case .sidebar(let action):
        return sidebar(action, state: state)
      case .detail(.tabBar(.agentLaunchFailed(let message))):
        return push(.warning(message))
      default:
        return .none
      }
    }
  }

  // MARK: - GitHub pull-request mutations

  private func gitHub(_ action: GitHubFeature.Action, state: RootFeature.State) -> Effect<RootFeature.Action> {
    switch action {
    case .mergeRequested(let worktreeID, let prNumber, _, _):
      return beginMutation(worktreeID, "Merging PR #\(prNumber)", state: state)
    case .closeRequested(let worktreeID, let prNumber, _):
      return beginMutation(worktreeID, "Closing PR #\(prNumber)", state: state)
    case .markReadyRequested(let worktreeID, let prNumber, _):
      return beginMutation(worktreeID, "Marking PR #\(prNumber) ready", state: state)
    case .rerunFailedJobsRequested(let worktreeID, _, _):
      return beginMutation(worktreeID, "Re-running failed jobs", state: state)

    case .mergeCompleted(let worktreeID, let prNumber, let result):
      return endMutation(worktreeID, result, success: "PR #\(prNumber) merged", failureAction: "Merge")
    case .closeCompleted(let worktreeID, let result):
      return endMutation(worktreeID, result, success: "PR closed", failureAction: "Close")
    case .markReadyCompleted(let worktreeID, let result):
      return endMutation(worktreeID, result, success: "PR marked ready", failureAction: "Mark ready")
    case .rerunFailedJobsCompleted(let worktreeID, let result):
      return endMutation(worktreeID, result, success: "Re-ran failed jobs", failureAction: "Rerun")

    default:
      return .none
    }
  }

  private func beginMutation(
    _ worktreeID: WorktreeID, _ title: String, state: RootFeature.State
  ) -> Effect<RootFeature.Action> {
    // GitHubFeature drops a request while another mutation runs on the same
    // worktree; that one's completion ends the shared id.
    guard !state.gitHub.mutating.contains(worktreeID) else { return .none }
    return begin(StatusActivity(id: .pullRequestMutation(worktreeID), title: title))
  }

  private func endMutation(
    _ worktreeID: WorktreeID,
    _ result: TaskResult<GitHubFeature.Action.VoidSuccess>,
    success: String,
    failureAction: String
  ) -> Effect<RootFeature.Action> {
    let outcome: StatusToast =
      switch result {
      case .success: .success(success)
      case .failure(let error): .failure(failureAction, reason: String(describing: error))
      }
    return end(.pullRequestMutation(worktreeID), outcome)
  }

  // MARK: - Editor

  private func editor(_ action: EditorFeature.Action, state: RootFeature.State) -> Effect<RootFeature.Action> {
    switch action {
    case .openRequested(let editorID, _, _):
      // `$EDITOR` spawns a pane in this window, which is progress enough; its
      // outcome still arrives as `.openSucceeded` / `.openFailed`, and ending
      // an id that was never begun just pushes the toast.
      guard editorID != EditorRegistry.shellEditorID else { return .none }
      let name = state.editor.descriptors.first { $0.id == editorID }?.displayName
      let title = name.map { "Opening in \($0)" } ?? "Opening in editor"
      return begin(StatusActivity(id: .editorOpen, title: title))
    case .openSucceeded(_, let displayName):
      return end(.editorOpen, .success("Opened in \(displayName)"))
    case .openFailed(let reason):
      return end(.editorOpen, .warning(StatusToast.oneLine(reason)))
    case .setProjectOverrideFailed(let reason):
      return push(.failure("Set default editor", reason: reason))
    default:
      return .none
    }
  }

  // MARK: - Sidebar

  private func sidebar(
    _ action: HierarchySidebarFeature.Action, state: RootFeature.State
  ) -> Effect<RootFeature.Action> {
    switch action {
    case .lifecycleNotice(let message):
      return push(.warning(StatusToast.oneLine(message)))

    case .projectPruneCompleted(let pruned, let error):
      if let error { return push(.failure("Prune", reason: error)) }
      switch pruned {
      case 0: return push(.success("No stale worktrees to prune"))
      case 1: return push(.success("Pruned 1 stale worktree"))
      default: return push(.success("Pruned \(pruned) stale worktrees"))
      }

    case .workspaceMemberRemoveConfirmed:
      guard let pending = state.sidebar.pendingWorkspaceMemberRemoval else { return .none }
      return begin(
        StatusActivity(
          id: .workspaceMemberRemoval(pending.worktreeID), title: "Removing \(pending.displayName)"))
    case .workspaceMemberRemoveFinished(let worktreeID, let message):
      return end(.workspaceMemberRemoval(worktreeID), message.map { .warning(StatusToast.oneLine($0)) })

    case .workspaceRemoveConfirmed:
      guard let pending = state.sidebar.pendingWorkspaceRemoval else { return .none }
      return begin(
        StatusActivity(id: .workspaceRemoval(pending.projectID), title: "Removing \(pending.displayName)"))
    case .workspaceRemoveFinished(let projectID, let message):
      return end(.workspaceRemoval(projectID), message.map { .warning(StatusToast.oneLine($0)) })

    default:
      return .none
    }
  }

  // MARK: - Helpers

  private func begin(_ activity: StatusActivity) -> Effect<RootFeature.Action> {
    .send(.statusBar(.begin(activity)))
  }

  private func end(_ id: StatusActivityID, _ outcome: StatusToast?) -> Effect<RootFeature.Action> {
    .send(.statusBar(.end(id: id, outcome: outcome)))
  }

  private func push(_ toast: StatusToast) -> Effect<RootFeature.Action> {
    .send(.statusBar(.push(toast)))
  }
}
