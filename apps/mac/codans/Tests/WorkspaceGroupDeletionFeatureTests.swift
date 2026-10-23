import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// A Workspace with one named group `feat` holding one member checkout,
/// whose group row runs a terminal.
private struct DeletionFixture {
  let groupID = WorkspaceGroupID()
  let busyPane = PaneID()
  let groupRow: Worktree
  let member: Worktree
  let project: Project

  init(deletion: GroupDeletionState? = nil) {
    groupRow = Worktree(
      name: "feat", path: "/ws/feat",
      tabs: [Tab(name: "server", panes: [Pane(id: busyPane, workingDirectory: "/ws/feat")])],
      workspaceSlot: WorkspaceSlot(groupID: groupID, role: .groupTerminal))
    member = Worktree(
      name: "app", path: "/ws/feat/app", branch: "feat", sourceGitRoot: "/src/app",
      workspaceSlot: WorkspaceSlot(groupID: groupID, role: .member))
    project = Project(
      name: "ws", rootPath: "/ws", worktrees: [groupRow, member], isWorkspace: true,
      workspaceGroups: [WorkspaceGroupRecord(id: groupID, name: "feat", kind: .named, deletion: deletion)])
  }

  func check(
    uncommitted: Int = 0, busy: Bool = false, deletableBranches: [String] = ["feat"], failure: String? = nil
  ) -> GroupDeletionCheck {
    GroupDeletionCheck(
      projectID: project.id, groupID: groupID, groupName: "feat",
      members: [
        .init(
          name: "app", worktreeID: member.id, path: member.path, branch: "feat",
          uncommittedCount: uncommitted, deletableBranches: deletableBranches, checkFailure: failure)
      ],
      busyPaneIDs: busy ? [busyPane] : [])
  }

  var target: WorkspaceGroupDeletionFeature.State.Target {
    .group(projectID: project.id, groupID: groupID, name: "feat")
  }
}

@MainActor
struct WorkspaceGroupDeletionFeatureTests {
  /// A group checks out one branch in every project; the confirmation names
  /// each branch once.
  @Test
  func theSameBranchInSeveralProjectsIsListedOnce() {
    let f = DeletionFixture()
    var check = f.check(deletableBranches: ["feat"])
    check.members.append(
      .init(
        name: "api", worktreeID: WorktreeID(), path: "/ws/feat/api", branch: "feat",
        deletableBranches: ["feat"]))
    check.members.append(
      .init(
        name: "lib", worktreeID: WorktreeID(), path: "/ws/feat/lib", branch: "feat-lib",
        deletableBranches: ["feat-lib"]))
    var state = WorkspaceGroupDeletionFeature.State(target: f.target)
    state.checks = [check]
    #expect(state.deletableBranches == ["feat", "feat-lib"])
  }

  @Test
  func deleteStaysDisabledUntilTheRisksAreAcknowledged() async {
    let f = DeletionFixture()
    let risky = f.check(uncommitted: 2, busy: true)
    let requests = LockIsolated<[GroupDeletionRequest]>([])
    let store = TestStore(initialState: WorkspaceGroupDeletionFeature.State(target: f.target)) {
      WorkspaceGroupDeletionFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
      $0.workspaceClient.checkGroupDeletion = { _, _ in risky }
      $0.workspaceClient.deleteGroup = { _, _, request in
        requests.withValue { $0.append(request) }
        return GroupDeletionOutcome(deletedGroup: true, removedMembers: ["app"], deletedBranches: ["feat"])
      }
    }

    await store.send(.checkRequested)
    await store.receive(\.checkLoaded) {
      $0.checks = [risky]
      $0.phase = .ready
      $0.runningTerminals = ["feat › server"]
    }
    #expect(store.state.hasRisks)
    #expect(!store.state.canDelete)
    // Without the acknowledgment the tap does nothing.
    await store.send(.deleteTapped)
    #expect(requests.value.isEmpty)

    await store.send(.deleteBranchesChanged(true)) { $0.deleteBranches = true }
    await store.send(.acknowledgesRisksChanged(true)) { $0.acknowledgesRisks = true }
    #expect(store.state.canDelete)
    await store.send(.deleteTapped) { $0.phase = .deleting }
    await store.receive(\.deletionFinished)
    await store.receive(\.delegate.completed)
    #expect(requests.value == [GroupDeletionRequest(deleteBranches: true, acknowledgeRisks: true)])
  }

  @Test
  func aFailedCheckBlocksUntilARetryPasses() async {
    let f = DeletionFixture()
    let failed = f.check(failure: "git status failed")
    let clean = f.check()
    let checks = LockIsolated([failed, clean])
    let store = TestStore(initialState: WorkspaceGroupDeletionFeature.State(target: f.target)) {
      WorkspaceGroupDeletionFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
      $0.workspaceClient.checkGroupDeletion = { _, _ in
        checks.withValue { $0.removeFirst() }
      }
    }

    await store.send(.checkRequested)
    await store.receive(\.checkLoaded) {
      $0.checks = [failed]
      $0.phase = .ready
    }
    #expect(store.state.isBlocked)
    #expect(!store.state.canDelete)
    // Acknowledging cannot unblock a failed check.
    await store.send(.acknowledgesRisksChanged(true)) { $0.acknowledgesRisks = true }
    #expect(!store.state.canDelete)

    await store.send(.checkRequested) { $0.phase = .checking }
    await store.receive(\.checkLoaded) {
      $0.checks = [clean]
      $0.phase = .ready
      $0.acknowledgesRisks = false
    }
    #expect(store.state.canDelete)
  }

  @Test
  func aRejectedDeleteShowsTheNewCheckAndAsksAgain() async {
    let f = DeletionFixture()
    let clean = f.check()
    let risky = f.check(uncommitted: 1)
    let store = TestStore(initialState: WorkspaceGroupDeletionFeature.State(target: f.target)) {
      WorkspaceGroupDeletionFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
      $0.workspaceClient.checkGroupDeletion = { _, _ in clean }
      $0.workspaceClient.deleteGroup = { _, _, _ in throw WorkspaceError.risksNotAcknowledged(risky) }
    }

    await store.send(.checkRequested)
    await store.receive(\.checkLoaded) {
      $0.checks = [clean]
      $0.phase = .ready
    }
    await store.send(.deleteTapped) { $0.phase = .deleting }
    await store.receive(\.deletionRejected) {
      $0.checks = [risky]
      $0.phase = .ready
      $0.errorMessage = WorkspaceError.risksNotAcknowledged(risky).localizedDescription
    }
    #expect(!store.state.canDelete)
  }

  @Test
  func deleteFilesChecksEveryNamedGroupAndDeletesThroughTheWorkspace() async {
    let f = DeletionFixture()
    let defaultGroup = WorkspaceGroupID()
    var project = f.project
    project.workspaceGroups.insert(WorkspaceGroupRecord(id: defaultGroup, name: "default", kind: .default), at: 0)
    let checked = LockIsolated<[WorkspaceGroupID]>([])
    let requests = LockIsolated<[WorkspaceRemovalRequest]>([])
    let clean = f.check()
    let store = TestStore(
      initialState: WorkspaceGroupDeletionFeature.State(target: .workspace(projectID: project.id, name: "ws"))
    ) {
      WorkspaceGroupDeletionFeature()
    } withDependencies: { [project] in
      $0.hierarchyClient.snapshot = { Catalog(projects: [project]) }
      $0.workspaceClient.checkGroupDeletion = { _, groupID in
        checked.withValue { $0.append(groupID) }
        return clean
      }
      $0.workspaceClient.removeWorkspace = { _, request in
        requests.withValue { $0.append(request) }
        return WorkspaceRemovalOutcome(deletedFolder: true)
      }
    }

    await store.send(.checkRequested)
    await store.receive(\.checkLoaded) {
      $0.checks = [clean]
      $0.phase = .ready
    }
    #expect(checked.value == [f.groupID])
    await store.send(.deleteTapped) { $0.phase = .deleting }
    await store.receive(\.deletionFinished)
    await store.receive(\.delegate.completed)
    #expect(requests.value == [.deleteOwnedFiles(GroupDeletionRequest())])
  }
}

// MARK: - Sidebar integration

extension WorkspaceGroupDeletionFeatureTests {
  @Test
  func deleteGroupOpensTheSheetOnNamedGroupsOnly() async {
    let f = DeletionFixture()
    let defaultGroup = WorkspaceGroupID()
    var project = f.project
    project.workspaceGroups.insert(WorkspaceGroupRecord(id: defaultGroup, name: "default", kind: .default), at: 0)
    let clean = f.check()
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: { [project] in
      $0.hierarchyClient.snapshot = { Catalog(projects: [project]) }
      $0.workspaceClient.checkGroupDeletion = { _, _ in clean }
    }

    await store.send(.deleteGroupTapped(projectID: project.id, groupID: defaultGroup))
    await store.send(.deleteGroupTapped(projectID: project.id, groupID: f.groupID)) {
      $0.groupDeletionSheet = WorkspaceGroupDeletionFeature.State(target: f.target)
    }
    await store.receive(\.groupDeletionSheet.checkRequested)
    await store.receive(\.groupDeletionSheet.checkLoaded) {
      $0.groupDeletionSheet?.checks = [clean]
      $0.groupDeletionSheet?.phase = .ready
    }
    await store.send(.groupDeletionSheet(.cancelTapped))
    await store.receive(\.groupDeletionSheet.delegate.dismissed) {
      $0.groupDeletionSheet = nil
    }
  }

  @Test
  func aPartialDeleteKeepsTheFailuresForTheRowAndRetrySeedsThem() async {
    let f = DeletionFixture(
      deletion: GroupDeletionState(deleteBranches: true, startedAt: Date(timeIntervalSince1970: 0)))
    let failure = GroupDeletionOutcome.Failure(name: "app", path: "/ws/feat/app", reason: "worktree is locked")
    let outcomes = LockIsolated([
      GroupDeletionOutcome(deletedGroup: false, failures: [failure]),
      GroupDeletionOutcome(deletedGroup: true, removedMembers: ["app"]),
    ])
    let store = TestStore(initialState: HierarchySidebarFeature.State()) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
      $0.workspaceClient.checkGroupDeletion = { _, _ in f.check() }
      $0.workspaceClient.deleteGroup = { _, _, _ in outcomes.withValue { $0.removeFirst() } }
    }
    store.exhaustivity = .off

    await store.send(.deleteGroupTapped(projectID: f.project.id, groupID: f.groupID))
    await store.receive(\.groupDeletionSheet.checkLoaded)
    await store.send(.groupDeletionSheet(.deleteTapped))
    await store.receive(\.groupDeletionSheet.delegate.completed)
    // The sheet closes; the group row keeps the failed items next to Retry.
    #expect(store.state.groupDeletionSheet == nil)
    #expect(store.state.workspaceGroupDeletionFailures[f.groupID] == [failure])

    // Retry from the row: the interrupted delete's branch choice and the
    // failed items come back with a fresh check.
    await store.send(.deleteGroupTapped(projectID: f.project.id, groupID: f.groupID))
    #expect(store.state.groupDeletionSheet?.deleteBranches == true)
    #expect(store.state.groupDeletionSheet?.previousFailures == [failure])
    await store.receive(\.groupDeletionSheet.checkLoaded)
    await store.send(.groupDeletionSheet(.deleteTapped))
    await store.receive(\.groupDeletionSheet.delegate.completed)
    #expect(store.state.workspaceGroupDeletionFailures[f.groupID] == nil)
  }

  @Test
  func removeWorkspaceFromSidebarDeletesNothing() async {
    let f = DeletionFixture()
    let requests = LockIsolated<[WorkspaceRemovalRequest]>([])
    var initial = HierarchySidebarFeature.State()
    initial.pendingWorkspaceRemoval = PendingProjectRemoval(projectID: f.project.id, displayName: "ws")
    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.workspaceClient.removeWorkspace = { _, request in
        requests.withValue { $0.append(request) }
        return WorkspaceRemovalOutcome(deletedFolder: false)
      }
    }

    await store.send(.workspaceRemoveConfirmed(deleteFiles: false)) { $0.pendingWorkspaceRemoval = nil }
    await store.receive(\.workspaceRemoveFinished)
    #expect(requests.value == [.sidebarOnly])
  }

  @Test
  func deleteWorkspaceFilesGoesThroughTheCheckedSheet() async {
    let f = DeletionFixture()
    var initial = HierarchySidebarFeature.State()
    initial.pendingWorkspaceRemoval = PendingProjectRemoval(projectID: f.project.id, displayName: "ws")
    let store = TestStore(initialState: initial) {
      HierarchySidebarFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
      $0.workspaceClient.checkGroupDeletion = { _, _ in f.check(uncommitted: 1) }
    }

    await store.send(.workspaceRemoveConfirmed(deleteFiles: true)) {
      $0.pendingWorkspaceRemoval = nil
      $0.groupDeletionSheet = WorkspaceGroupDeletionFeature.State(
        target: .workspace(projectID: f.project.id, name: "ws"))
    }
    await store.receive(\.groupDeletionSheet.checkRequested)
    await store.receive(\.groupDeletionSheet.checkLoaded) {
      $0.groupDeletionSheet?.checks = [f.check(uncommitted: 1)]
      $0.groupDeletionSheet?.phase = .ready
    }
    #expect(store.state.groupDeletionSheet?.canDelete == false)
  }
}
