import CodansCore
import Foundation
import Testing

@testable import Codans

/// Workspace half of the manager: registering a root, mapping manifest
/// groups onto catalog rows, the group-level mutations later flows call, and
/// the per-role pane environment.
@MainActor
struct HierarchyManagerWorkspaceTests {
  var fakeRuntime: FakeHierarchyRuntime!
  var store: CatalogStore!
  var manager: HierarchyManager!

  init() {
    let tempURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    fakeRuntime = FakeHierarchyRuntime()
    store = CatalogStore(fileURL: tempURL)
    manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
  }

  private typealias Group = HierarchyManager.WorkspaceGroupObservation
  private typealias Row = HierarchyManager.WorkspaceRowObservation

  private let defaultID = WorkspaceGroupID.derived(rootPath: "/tmp/ws", key: "default")
  private let existingID = WorkspaceGroupID.derived(rootPath: "/tmp/ws", key: "existing")

  /// `default` with one reference to `/src/app`, and the migrated
  /// `existing` group at the root with one member.
  private func standardGroups(
    appBranch: String? = "main",
    referenceExists: Bool = true,
    memberExists: Bool = true,
    memberBranch: String? = "feat/x"
  ) -> [Group] {
    [
      Group(
        id: defaultID, name: "default", kind: .default, deletion: nil,
        rows: [
          Row(name: "default", path: "/tmp/ws/default", role: .groupTerminal, exists: true),
          Row(
            name: "app", path: "/src/app", role: .reference, exists: referenceExists,
            branch: appBranch, sourceGitRoot: "/src/app"),
        ]),
      Group(
        id: existingID, name: "existing", kind: .named, deletion: nil,
        rows: [
          Row(name: "existing", path: "/tmp/ws", role: .groupTerminal, exists: true),
          Row(
            name: "app", path: "/tmp/ws/app", role: .member, exists: memberExists,
            branch: memberBranch, sourceGitRoot: "/src/app"),
        ]),
    ]
  }

  private func project(_ id: ProjectID, in other: HierarchyManager? = nil) throws -> Project {
    try #require((other ?? manager).catalog.projects.first { $0.id == id })
  }

  /// A manager over a restored catalog, as at launch.
  private func restored(_ project: Project) -> HierarchyManager {
    HierarchyManager(catalog: Catalog(projects: [project]), store: store, runtime: fakeRuntime)
  }

  private func row(_ project: Project, path: String) -> Worktree? {
    project.worktrees.first { $0.path == HierarchyManager.canonicalPath(path) }
  }

  // MARK: Registration

  @Test
  func addWorkspaceProjectSeedsNoRowAndIgnoresGitRoot() throws {
    let projectID = manager.addProject(
      name: "ws", rootPath: "/tmp/ws", gitRoot: "/tmp", isWorkspace: true)
    let project = try project(projectID)
    #expect(project.kind == .workspace)
    #expect(project.gitRoot == nil)
    #expect(project.worktrees.isEmpty)
    #expect(project.selectedWorktreeID == nil)
    #expect(project.rowWorktree == nil)
  }

  // MARK: Reconcile

  @Test
  func reconcileRegistersGroupsAndAppendsRowsWithSlots() throws {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())

    let project = try project(projectID)
    #expect(project.workspaceGroups.map(\.id) == [defaultID, existingID])
    #expect(project.workspaceGroups.map(\.name) == ["default", "existing"])
    #expect(project.workspaceGroups.allSatisfy { !$0.isExpanded })
    #expect(project.worktrees.count == 4)
    let reference = try #require(row(project, path: "/src/app"))
    #expect(reference.workspaceSlot == WorkspaceSlot(groupID: defaultID, role: .reference))
    #expect(reference.name == "app")
    #expect(reference.branch == "main")
    let member = try #require(row(project, path: "/tmp/ws/app"))
    #expect(member.workspaceSlot == WorkspaceSlot(groupID: existingID, role: .member))
    #expect(member.branch == "feat/x")
    #expect(member.sourceGitRoot == "/src/app")
    let rootRow = try #require(row(project, path: "/tmp/ws"))
    #expect(rootRow.workspaceSlot == WorkspaceSlot(groupID: existingID, role: .groupTerminal))
    #expect(rootRow.name == "existing")
  }

  @Test
  func reconcileKeepsMigratedRowsAndAssignsSlotsInPlace() throws {
    let rootRow = Worktree(name: "ws", path: "/tmp/ws", tabs: [Tab(name: "t")])
    let child = Worktree(name: "app-old-name", path: "/tmp/ws/app", branch: "feat/x")
    let project = Project(
      name: "ws", rootPath: "/tmp/ws", worktrees: [rootRow, child],
      selectedWorktreeID: child.id, isWorkspace: true)
    let manager = restored(project)

    manager.reconcileWorkspaceGroups(projectID: project.id, groups: standardGroups())

    let after = try self.project(project.id, in: manager)
    let root = try #require(after.worktrees.first { $0.id == rootRow.id })
    #expect(root.tabs == rootRow.tabs)
    #expect(root.name == "ws")
    #expect(root.workspaceSlot == WorkspaceSlot(groupID: existingID, role: .groupTerminal))
    let member = try #require(after.worktrees.first { $0.id == child.id })
    #expect(member.name == "app-old-name")
    #expect(member.workspaceSlot?.role == .member)
    #expect(after.selectedWorktreeID == child.id)
  }

  @Test
  func reconcileKeepsExpansionAndDeletionStateByGroupID() throws {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())
    let deletion = GroupDeletionState(deleteBranches: true, startedAt: Date(timeIntervalSince1970: 1))
    manager.setWorkspaceGroupExpanded(projectID: projectID, groupID: existingID, isExpanded: true)
    manager.setWorkspaceGroupDeletion(projectID: projectID, groupID: existingID, deletion: deletion)

    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())

    let record = try #require(try project(projectID).workspaceGroups.first { $0.id == existingID })
    #expect(record.isExpanded)
    #expect(record.deletion == deletion)
  }

  @Test
  func repeatReconcileIsStable() throws {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())
    let before = manager.catalog
    let result = manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())
    #expect(result == .init())
    #expect(manager.catalog == before)
  }

  @Test
  func memberBranchSwitchRefreshesBranchAndKeepsTheRow() throws {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())
    let memberID = try #require(row(try project(projectID), path: "/tmp/ws/app")).id
    let tabID = try manager.createTab(in: memberID, in: projectID, name: "t")

    let result = manager.reconcileWorkspaceGroups(
      projectID: projectID, groups: standardGroups(memberBranch: "fix/y"))

    #expect(result.updated == 1)
    let member = try #require(try project(projectID).worktrees.first { $0.id == memberID })
    #expect(member.branch == "fix/y")
    #expect(member.name == "app")
    #expect(member.tabs.map(\.id) == [tabID])
  }

  @Test
  func missingMemberIsSoftArchivedAndMissingSourceKeepsTheReference() throws {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())

    let result = manager.reconcileWorkspaceGroups(
      projectID: projectID,
      groups: standardGroups(referenceExists: false, memberExists: false))

    #expect(result.archived == 1)
    let project = try project(projectID)
    let member = try #require(row(project, path: "/tmp/ws/app"))
    #expect(member.archived)
    #expect(member.archivedAt != nil)
    let reference = try #require(row(project, path: "/src/app"))
    #expect(!reference.archived)
    #expect(project.unavailableWorkspaceRows == [reference.id])
    #expect(fakeRuntime.announceHierarchyMutatedCount == 1)

    // The source comes back: the reference is available again.
    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())
    #expect(try self.project(projectID).unavailableWorkspaceRows.isEmpty)
  }

  @Test
  func missingReferenceIsNotAddedAndUnnamedRowsAreLeftAlone() throws {
    let stray = Worktree(name: "stray", path: "/tmp/ws/stray")
    let project = Project(name: "ws", rootPath: "/tmp/ws", worktrees: [stray], isWorkspace: true)
    let manager = restored(project)

    manager.reconcileWorkspaceGroups(
      projectID: project.id, groups: standardGroups(referenceExists: false))

    let after = try self.project(project.id, in: manager)
    #expect(row(after, path: "/src/app") == nil)
    #expect(after.worktrees.first { $0.id == stray.id } == stray)
  }

  @Test
  func reconcileIsANoOpOnNonWorkspaceProjects() throws {
    let projectID = manager.addProject(name: "p", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    let result = manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())
    #expect(result == .init())
    let project = try project(projectID)
    #expect(project.worktrees.isEmpty)
    #expect(project.workspaceGroups.isEmpty)
  }

  // MARK: Membership

  @Test
  func membershipCountsMembersOnlyNotReferencesOrGroupRows() throws {
    let sourceID = manager.addProject(name: "app", rootPath: "/src/app", gitRoot: "/src/app")
    let sourceMain = try manager.createWorktree(
      in: sourceID, name: "app", path: "/src/app", branch: "main")
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())

    #expect(manager.workspaceMembership(forPath: "/src/app") == nil)
    #expect(manager.workspaceMembership(forPath: "/tmp/ws") == nil)
    #expect(manager.workspaceMembership(forPath: "/tmp/ws/default") == nil)
    #expect(manager.workspaceMembership(forPath: "/tmp/ws/app")?.projectID == projectID)
    #expect(manager.workspaceMemberships[sourceMain] == nil)
  }

  @Test
  func displayMembershipRefreshesWhenARowChangesRole() throws {
    let child = Worktree(name: "app", path: "/tmp/ws/app")
    let project = Project(name: "ws", rootPath: "/tmp/ws", worktrees: [child], isWorkspace: true)
    let manager = restored(project)
    // No slot yet: not a member.
    #expect(manager.workspaceMemberships[child.id] == nil)

    manager.reconcileWorkspaceGroups(projectID: project.id, groups: standardGroups())

    #expect(manager.workspaceMemberships[child.id]?.projectID == project.id)
  }

  // MARK: Group mutations

  @Test
  func groupExpansionAndDeletionAreStoredPerGroup() throws {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())

    manager.setWorkspaceGroupExpanded(projectID: projectID, groupID: defaultID, isExpanded: true)
    let deletion = GroupDeletionState(deleteBranches: false, startedAt: Date(timeIntervalSince1970: 2))
    manager.setWorkspaceGroupDeletion(projectID: projectID, groupID: existingID, deletion: deletion)

    var groups = try project(projectID).workspaceGroups
    #expect(groups.map(\.isExpanded) == [true, false])
    #expect(groups.map(\.deletion) == [nil, deletion])

    manager.setWorkspaceGroupDeletion(projectID: projectID, groupID: existingID, deletion: nil)
    groups = try project(projectID).workspaceGroups
    #expect(groups[1].deletion == nil)
  }

  @Test
  func removeWorkspaceRowsDropsRowsIncludingTheRootGroupRow() throws {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())
    let before = try project(projectID)
    let rootRow = try #require(row(before, path: "/tmp/ws"))
    let member = try #require(row(before, path: "/tmp/ws/app"))
    try manager.selectWorktree(rootRow.id, in: projectID)

    manager.removeWorkspaceRows(projectID: projectID, worktreeIDs: [rootRow.id, member.id])

    let after = try project(projectID)
    #expect(after.worktrees.count == 2)
    #expect(!after.worktrees.contains { $0.id == rootRow.id || $0.id == member.id })
    #expect(after.selectedWorktreeID != rootRow.id)
  }

  @Test
  func busyPanesCoverTheGroupRowAndItsMembersOnly() async throws {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())
    let project = try project(projectID)
    func busyPane(at path: String) async throws -> PaneID {
      let rowID = try #require(row(project, path: path)).id
      let tabID = try manager.createTab(in: rowID, in: projectID, name: nil)
      let paneID = try await manager.openPane(
        in: tabID, in: rowID, in: projectID, workingDirectory: path, initialCommand: nil)
      manager.setPaneCommandBusy(paneID, true)
      return paneID
    }
    let rootPane = try await busyPane(at: "/tmp/ws")
    let memberPane = try await busyPane(at: "/tmp/ws/app")
    _ = try await busyPane(at: "/src/app")

    let busy = manager.workspaceGroupBusyPanes(projectID: projectID, groupID: existingID)
    #expect(Set(busy) == [rootPane, memberPane])
  }

  // MARK: Environment

  @Test
  func paneEnvironmentNamesTheGroupOfTheRow() async throws {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    manager.reconcileWorkspaceGroups(projectID: projectID, groups: standardGroups())
    let project = try project(projectID)
    func env(at path: String) async throws -> [String: String] {
      let rowID = try #require(row(project, path: path)).id
      let tabID = try manager.createTab(in: rowID, in: projectID, name: nil)
      _ = try await manager.openPane(
        in: tabID, in: rowID, in: projectID, workingDirectory: path, initialCommand: nil,
        env: ["CODANS_WORKSPACE_GROUP": "stale"])
      return try #require(fakeRuntime.ensureSurfaceCalls.last).env
    }
    let groupKey = BuiltinEnvVar.workspaceGroup.key
    let dirKey = BuiltinEnvVar.workspaceGroupDirectory.key

    let reference = try await env(at: "/src/app")
    #expect(reference[BuiltinEnvVar.workspaceRoot.key] == "/tmp/ws")
    #expect(reference[groupKey] == "default")
    #expect(reference[dirKey] == HierarchyManager.canonicalPath("/tmp/ws/default"))

    let member = try await env(at: "/tmp/ws/app")
    #expect(member[groupKey] == "existing")
    #expect(member[dirKey] == HierarchyManager.canonicalPath("/tmp/ws"))

    let groupRow = try await env(at: "/tmp/ws/default")
    #expect(groupRow[groupKey] == "default")
    #expect(groupRow[dirKey] == HierarchyManager.canonicalPath("/tmp/ws/default"))
  }

  @Test
  func builtinEnvDropsWorkspaceKeysOutsideAWorkspace() {
    let stale = [
      "CODANS_WORKSPACE_ROOT": "stale", "CODANS_WORKSPACE_GROUP": "stale",
      "CODANS_WORKSPACE_GROUP_DIR": "stale",
    ]
    let outside = HierarchyManager.injectingBuiltins(stale, worktreePath: "/tmp/p", rootPath: "/tmp/p")
    #expect(outside[BuiltinEnvVar.workspaceRoot.key] == nil)
    #expect(outside[BuiltinEnvVar.workspaceGroup.key] == nil)
    #expect(outside[BuiltinEnvVar.workspaceGroupDirectory.key] == nil)
    #expect(BuiltinEnvVar.reservedKeys.isSuperset(of: stale.keys))
  }

  @Test
  func manifestSetterIsTransient() throws {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    let manifest = WorkspaceGroupsManifest(title: "Checkout Flow")
    manager.setProjectWorkspaceManifest(projectID: projectID, manifest: manifest)
    #expect(try project(projectID).workspace == manifest)
  }
}
