import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

@MainActor
struct CreateWorkspaceFeatureTests {
  private static func defaultRoot(_ slug: String) -> String {
    WorkspaceLayout.defaultWorkspacesDirectory()
      .appending(path: slug, directoryHint: .isDirectory).path
  }

  @Test
  func titleDerivesFolderAndBranchUntilEditedByHand() async {
    let store = TestStore(initialState: CreateWorkspaceFeature.State(candidates: [])) {
      CreateWorkspaceFeature()
    }
    await store.send(.titleChanged("Checkout Flow")) {
      $0.titleDraft = "Checkout Flow"
      $0.rootPathDraft = Self.defaultRoot("checkout-flow")
      $0.branchDraft = "checkout-flow"
    }
    await store.send(.branchChanged("feat/x")) {
      $0.branchDraft = "feat/x"
      $0.branchEditedManually = true
    }
    await store.send(.rootPathChanged("/tmp/custom")) {
      $0.rootPathDraft = "/tmp/custom"
      $0.rootPathEditedManually = true
    }
    // Neither derived field moves once the user owns it.
    await store.send(.titleChanged("Other")) {
      $0.titleDraft = "Other"
    }
  }

  @Test
  func createHandsThePlanToTheClientAndDelegatesOnSuccess() async {
    let candidate = CreateWorkspaceFeature.Candidate(id: ProjectID(), name: "app", gitRoot: "/src/app")
    let created = ProjectID()
    var initial = CreateWorkspaceFeature.State(candidates: [candidate])
    initial.titleDraft = "T"
    initial.rootPathDraft = "/tmp/ws"
    initial.branchDraft = "feat/t"
    initial.baseRefDraft = "main"
    initial.selectedCandidateIDs = [candidate.id]
    initial.localRepos = ["/src/lib"]

    let store = TestStore(initialState: initial) {
      CreateWorkspaceFeature()
    } withDependencies: {
      $0[WorkspaceClient.self] = WorkspaceClient(
        create: { plan in
          #expect(plan.title == "T")
          #expect(plan.rootPath == "/tmp/ws")
          #expect(plan.members.map(\.name) == ["app", "lib"])
          #expect(plan.members.map(\.sourceGitRoot) == ["/src/app", "/src/lib"])
          #expect(plan.members[0].checkout == .newBranch(branch: "feat/t", baseRef: "main"))
          return created
        },
        add: { _, _ in WorktreeID() },
        drop: { _, _, _ in nil },
        remove: { _, _ in WorkspaceRemovalOutcome(deletedFolder: false) }
      )
    }
    #expect(store.state.canCreate)
    await store.send(.createButtonTapped) {
      $0.isCreating = true
    }
    await store.receive(\.createSucceeded) {
      $0.isCreating = false
    }
    await store.receive(\.delegate.created)
  }

  @Test
  func createSurfacesValidationWithoutCallingTheClient() async {
    var initial = CreateWorkspaceFeature.State(candidates: [])
    initial.titleDraft = "T"
    initial.rootPathDraft = "/tmp/ws"
    initial.branchDraft = "t"
    initial.localRepos = ["/src/only"]
    let store = TestStore(initialState: initial) {
      CreateWorkspaceFeature()
    } withDependencies: {
      $0[WorkspaceClient.self] = WorkspaceClient(
        create: { _ in
          Issue.record("client must not be called for an invalid plan")
          return ProjectID()
        },
        add: { _, _ in WorktreeID() },
        drop: { _, _, _ in nil },
        remove: { _, _ in WorkspaceRemovalOutcome(deletedFolder: false) }
      )
    }
    #expect(!store.state.canCreate)
    await store.send(.createButtonTapped) {
      $0.errorMessage = WorkspacePlan.ValidationIssue.tooFewMembers(1).description
    }
  }

  @Test
  func createFailureKeepsTheSheetOpenWithTheMessage() async {
    let a = CreateWorkspaceFeature.Candidate(id: ProjectID(), name: "a", gitRoot: "/src/a")
    let b = CreateWorkspaceFeature.Candidate(id: ProjectID(), name: "b", gitRoot: "/src/b")
    var initial = CreateWorkspaceFeature.State(candidates: [a, b])
    initial.titleDraft = "T"
    initial.rootPathDraft = "/tmp/ws"
    initial.branchDraft = "t"
    initial.selectedCandidateIDs = [a.id, b.id]
    let store = TestStore(initialState: initial) {
      CreateWorkspaceFeature()
    } withDependencies: {
      $0[WorkspaceClient.self] = WorkspaceClient(
        create: { _ in throw WorkspaceError.rootAlreadyWorkspace(path: "/tmp/ws") },
        add: { _, _ in WorktreeID() },
        drop: { _, _, _ in nil },
        remove: { _, _ in WorkspaceRemovalOutcome(deletedFolder: false) }
      )
    }
    await store.send(.createButtonTapped) {
      $0.isCreating = true
    }
    await store.receive(\.createFailed) {
      $0.isCreating = false
      $0.errorMessage = WorkspaceError.rootAlreadyWorkspace(path: "/tmp/ws").localizedDescription
    }
  }
}
