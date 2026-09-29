import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

/// The child-action → status-bar mapping, exercised on the bindings reducer
/// alone: it only emits `.statusBar(...)` actions, which it does not reduce.
@MainActor
struct StatusBarRootBindingsTests {
  private let worktreeID = WorktreeID(raw: UUID())
  private let path = URL(fileURLWithPath: "/tmp/wt")

  private func makeStore(
    _ mutate: (inout RootFeature.State) -> Void = { _ in }
  ) -> TestStore<RootFeature.State, RootFeature.Action> {
    var state = RootFeature.State()
    mutate(&state)
    return TestStore(initialState: state) { StatusBarRootBindings() }
  }

  @Test
  func mergeBeginsAnActivityAndItsCompletionEndsIt() async {
    let store = makeStore()
    await store.send(.gitHub(.mergeRequested(worktreeID, prNumber: 12, strategy: .squash, worktreePath: path)))
    await store.receive(
      .statusBar(.begin(StatusActivity(id: .pullRequestMutation(worktreeID), title: "Merging PR #12"))))
    await store.send(.gitHub(.mergeCompleted(worktreeID, prNumber: 12, .success(.init()))))
    await store.receive(
      .statusBar(.end(id: .pullRequestMutation(worktreeID), outcome: .success("PR #12 merged"))))
  }

  @Test
  func requestRejectedByARunningMutationBeginsNothing() async {
    let store = makeStore { $0.gitHub.mutating = [worktreeID] }
    await store.send(.gitHub(.closeRequested(worktreeID, prNumber: 3, worktreePath: path)))
  }

  @Test
  func mutationFailureEndsWithTheVerbAndFirstLine() async {
    struct Boom: Error, CustomStringConvertible { var description: String { "not mergeable\ntrace" } }
    let store = makeStore()
    await store.send(.gitHub(.markReadyCompleted(worktreeID, .failure(Boom()))))
    await store.receive(
      .statusBar(
        .end(id: .pullRequestMutation(worktreeID), outcome: .warning("Mark ready failed: not mergeable"))))
  }

  @Test
  func editorOpenBeginsWithTheEditorNameExceptForShellEditor() async {
    let store = makeStore()
    await store.send(.editor(.openRequested(editorID: nil, worktreePath: "/tmp/wt", projectID: nil)))
    await store.receive(.statusBar(.begin(StatusActivity(id: .editorOpen, title: "Opening in editor"))))
    await store.send(
      .editor(.openRequested(editorID: EditorRegistry.shellEditorID, worktreePath: "/tmp/wt", projectID: nil)))
    await store.send(.editor(.openSucceeded(editorID: "zed", displayName: "Zed")))
    await store.receive(.statusBar(.end(id: .editorOpen, outcome: .success("Opened in Zed"))))
  }

  @Test
  func sidebarOutcomesBecomeToasts() async {
    let store = makeStore()
    await store.send(.sidebar(.lifecycleNotice(message: "Delete failed: dirty index\nhint")))
    await store.receive(.statusBar(.push(.warning("Delete failed: dirty index"))))
    await store.send(.sidebar(.projectPruneCompleted(pruned: 2, error: nil)))
    await store.receive(.statusBar(.push(.success("Pruned 2 stale worktrees"))))
    await store.send(.sidebar(.projectPruneCompleted(pruned: 0, error: "fatal: nope")))
    await store.receive(.statusBar(.push(.warning("Prune failed: fatal: nope"))))
  }

  @Test
  func workspaceRemovalIsAnActivityOnlyWhenConfirmed() async {
    let projectID = ProjectID()
    let store = makeStore {
      $0.sidebar.pendingWorkspaceRemoval = PendingProjectRemoval(projectID: projectID, displayName: "shop")
    }
    await store.send(.sidebar(.workspaceRemoveConfirmed(deleteFiles: true)))
    await store.receive(
      .statusBar(.begin(StatusActivity(id: .workspaceRemoval(projectID), title: "Removing shop"))))
    await store.send(.sidebar(.workspaceRemoveFinished(projectID: projectID, message: nil)))
    await store.receive(.statusBar(.end(id: .workspaceRemoval(projectID), outcome: nil)))

    // No pending confirmation: the sidebar ignores the confirm, so must we.
    let idle = makeStore()
    await idle.send(.sidebar(.workspaceRemoveConfirmed(deleteFiles: false)))
  }

  @Test
  func tabBarAgentLaunchFailureBecomesAWarning() async {
    let store = makeStore()
    await store.send(.detail(.tabBar(.agentLaunchFailed(message: "Launch Codex failed: boom"))))
    await store.receive(.statusBar(.push(.warning("Launch Codex failed: boom"))))
  }
}
