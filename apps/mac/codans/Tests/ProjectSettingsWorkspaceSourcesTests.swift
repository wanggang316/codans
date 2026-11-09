import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// The Workspace settings source list: adding and removing source projects
/// goes through `WorkspaceClient`, and removing touches only the reference.
@MainActor
struct ProjectSettingsWorkspaceSourcesTests {
  private struct Fixture {
    let busyTab = Tab(name: "tests")
    let groupID = WorkspaceGroupID()
    let project: Project
    let reference: Worktree

    init() {
      reference = Worktree(
        name: "app", path: "/src/app", branch: "main", tabs: [busyTab], sourceGitRoot: "/src/app",
        workspaceSlot: WorkspaceSlot(groupID: groupID, role: .reference))
      project = Project(
        name: "ws", rootPath: "/ws", worktrees: [reference], isWorkspace: true,
        workspaceGroups: [WorkspaceGroupRecord(id: groupID, name: "default", kind: .default)])
    }
  }

  @Test
  func removingASourceConfirmsWithItsTerminalsAndRemovesOnlyTheReference() async {
    let f = Fixture()
    let removed = LockIsolated<[(ProjectID, String)]>([])
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: f.project.id, kind: .workspace)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
      $0.hierarchyClient.tabIsDirty = { $0 == f.busyTab.id }
      $0.workspaceClient.removeSource = { projectID, sourceGitRoot in
        removed.withValue { $0.append((projectID, sourceGitRoot)) }
      }
    }

    await store.send(.workspaceSourceRemoveTapped(f.reference.id)) {
      $0.pendingSourceRemoval = PendingWorkspaceSourceRemoval(
        worktreeID: f.reference.id, in: f.project, tabIsDirty: { $0 == f.busyTab.id })
    }
    #expect(store.state.pendingSourceRemoval?.runningTerminals == ["app › tests"])

    await store.send(.workspaceSourceRemoveConfirmed) { $0.pendingSourceRemoval = nil }
    await store.receive(\.workspaceSourcesChanged)
    #expect(removed.value.count == 1)
    #expect(removed.value.first?.0 == f.project.id)
    #expect(removed.value.first?.1 == "/src/app")
  }

  @Test
  func cancellingTheRemovalRemovesNothing() async {
    let f = Fixture()
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: f.project.id, kind: .workspace)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
      $0.hierarchyClient.tabIsDirty = { _ in false }
    }

    await store.send(.workspaceSourceRemoveTapped(f.reference.id)) {
      $0.pendingSourceRemoval = PendingWorkspaceSourceRemoval(
        worktreeID: f.reference.id, in: f.project, tabIsDirty: { _ in false })
    }
    await store.send(.workspaceSourceRemoveCancelled) { $0.pendingSourceRemoval = nil }
  }

  @Test
  func aFailedRemovalIsShownInThePane() async {
    let f = Fixture()
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: f.project.id, kind: .workspace)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient.snapshot = { Catalog(projects: [f.project]) }
      $0.hierarchyClient.tabIsDirty = { _ in false }
      $0.workspaceClient.removeSource = { _, path in throw WorkspaceError.sourceNotFound(path: path) }
    }

    await store.send(.workspaceSourceRemoveTapped(f.reference.id)) {
      $0.pendingSourceRemoval = PendingWorkspaceSourceRemoval(
        worktreeID: f.reference.id, in: f.project, tabIsDirty: { _ in false })
    }
    await store.send(.workspaceSourceRemoveConfirmed) { $0.pendingSourceRemoval = nil }
    await store.receive(\.workspaceSourcesChanged) {
      $0.lastWriteFailure = WorkspaceError.sourceNotFound(path: "/src/app").localizedDescription
    }
  }

  @Test
  func addingAnOpenProjectOrAFolderAddsALocalSource() async {
    let f = Fixture()
    let added = LockIsolated<[WorkspaceSource]>([])
    let picks = LockIsolated<[URL?]>([URL(fileURLWithPath: "/src/tool"), nil])
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: f.project.id, kind: .workspace)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.workspaceClient.addSource = { _, source in
        added.withValue { $0.append(source) }
        return WorktreeID()
      }
      $0.folderPickerClient.pick = { _ in picks.withValue { $0.removeFirst() } }
    }

    await store.send(.workspaceAddSourceTapped(path: "/src/lib"))
    await store.receive(\.workspaceSourcesChanged)
    await store.send(.workspaceAddFolderTapped)
    await store.receive(\.workspaceAddSourceTapped)
    await store.receive(\.workspaceSourcesChanged)
    // A cancelled picker adds nothing.
    await store.send(.workspaceAddFolderTapped)
    #expect(
      added.value == [
        WorkspaceSource(location: .local(path: "/src/lib")),
        WorkspaceSource(location: .local(path: "/src/tool")),
      ])
  }
}
