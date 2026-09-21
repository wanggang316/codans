import CodansCore
import Foundation
import Testing

@testable import Codans

/// Workspace half of the manager: registering a root, merging manifest
/// observations into child rows, and the guards that keep the root row alive.
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

  private typealias Observation = HierarchyManager.WorkspaceChildObservation

  @Test
  func addWorkspaceProjectSeedsRootRowAndIgnoresGitRoot() {
    let projectID = manager.addProject(
      name: "ws", rootPath: "/tmp/ws", gitRoot: "/tmp", isWorkspace: true)
    let project = manager.catalog.projects[0]
    #expect(project.id == projectID)
    #expect(project.kind == .workspace)
    #expect(project.gitRoot == nil)
    #expect(project.worktrees.count == 1)
    #expect(project.worktrees[0].path == "/tmp/ws")
    #expect(project.selectedWorktreeID == project.worktrees[0].id)
  }

  @Test
  func reconcileAppendsExistingChildrenAndSkipsMissingOnes() {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    let result = manager.reconcileWorkspaceChildren(
      projectID: projectID,
      observations: [
        Observation(
          name: "app", path: "/tmp/ws/app", exists: true, branch: "feat/x",
          sourceGitRoot: "/src/app"),
        Observation(name: "api", path: "/tmp/ws/api", exists: false, branch: nil, sourceGitRoot: nil),
      ]
    )
    #expect(result.appended == 1)
    #expect(result.archived == 0)
    let rows = manager.catalog.projects[0].worktrees
    #expect(rows.count == 2)
    #expect(rows[1].name == "app")
    #expect(rows[1].branch == "feat/x")
    #expect(rows[1].sourceGitRoot == "/src/app")
    #expect(rows[1].path == HierarchyManager.canonicalPath("/tmp/ws/app"))
  }

  @Test
  func reconcileRefreshesBranchInPlaceWithoutRenaming() throws {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    _ = manager.reconcileWorkspaceChildren(
      projectID: projectID,
      observations: [
        Observation(
          name: "app", path: "/tmp/ws/app", exists: true, branch: "feat/x", sourceGitRoot: nil)
      ])
    let rowID = manager.catalog.projects[0].worktrees[1].id
    let tabID = try manager.createTab(in: rowID, in: projectID, name: "t")

    let result = manager.reconcileWorkspaceChildren(
      projectID: projectID,
      observations: [
        Observation(
          name: "app", path: "/tmp/ws/app", exists: true, branch: "main",
          sourceGitRoot: "/src/app")
      ])
    #expect(result.updated == 2)
    let row = manager.catalog.projects[0].worktrees[1]
    #expect(row.id == rowID)
    #expect(row.name == "app")
    #expect(row.branch == "main")
    #expect(row.sourceGitRoot == "/src/app")
    #expect(row.tabs.map(\.id) == [tabID])
  }

  @Test
  func reconcileSoftArchivesVanishedChildrenAndSparesPinnedOnes() {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    _ = manager.reconcileWorkspaceChildren(
      projectID: projectID,
      observations: [
        Observation(name: "app", path: "/tmp/ws/app", exists: true, branch: "a", sourceGitRoot: nil),
        Observation(name: "api", path: "/tmp/ws/api", exists: true, branch: "b", sourceGitRoot: nil),
      ])
    let apiID = manager.catalog.projects[0].worktrees[2].id
    manager.setWorktreePinned(worktreeID: apiID, isPinned: true)

    let result = manager.reconcileWorkspaceChildren(
      projectID: projectID,
      observations: [
        Observation(name: "app", path: "/tmp/ws/app", exists: false, branch: nil, sourceGitRoot: nil),
        Observation(name: "api", path: "/tmp/ws/api", exists: false, branch: nil, sourceGitRoot: nil),
      ])
    #expect(result.archived == 1)
    let rows = manager.catalog.projects[0].worktrees
    let app = try? #require(rows.first { $0.name == "app" })
    #expect(app?.archived == true)
    #expect(app?.archivedAt != nil)
    let api = rows.first { $0.name == "api" }
    #expect(api?.archived == false)
    #expect(fakeRuntime.announceHierarchyMutatedCount == 1)
  }

  @Test
  func reconcileNeverTouchesTheRootRowOrEmptyObservations() {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    _ = manager.reconcileWorkspaceChildren(
      projectID: projectID,
      observations: [
        Observation(name: "app", path: "/tmp/ws/app", exists: true, branch: "a", sourceGitRoot: nil),
        // An entry pointing at the root itself is ignored.
        Observation(name: "ws", path: "/tmp/ws", exists: false, branch: nil, sourceGitRoot: nil),
      ])
    let before = manager.catalog.projects[0].worktrees
    #expect(before.count == 2)
    #expect(!before[0].archived)

    // A manifest that names nothing archives nothing.
    let result = manager.reconcileWorkspaceChildren(projectID: projectID, observations: [])
    #expect(result == (0, 0, 0))
    #expect(manager.catalog.projects[0].worktrees == before)
  }

  @Test
  func reconcileIsANoOpOnNonWorkspaceProjects() {
    let projectID = manager.addProject(name: "p", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    let result = manager.reconcileWorkspaceChildren(
      projectID: projectID,
      observations: [
        Observation(name: "x", path: "/tmp/p/x", exists: true, branch: "x", sourceGitRoot: nil)
      ])
    #expect(result == (0, 0, 0))
    #expect(manager.catalog.projects[0].worktrees.isEmpty)
  }

  @Test
  func removeWorktreeRefusesTheMainCheckout() {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    let rootID = manager.catalog.projects[0].worktrees[0].id
    #expect(throws: HierarchyError.self) {
      try manager.removeWorktree(rootID, from: projectID)
    }
    #expect(manager.catalog.projects[0].worktrees.count == 1)
  }

  @Test
  func membershipLookupResolvesChildRowsByCanonicalPath() {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    _ = manager.reconcileWorkspaceChildren(
      projectID: projectID,
      observations: [
        Observation(name: "app", path: "/tmp/ws/app", exists: true, branch: "a", sourceGitRoot: nil)
      ])
    let hit = manager.workspaceMembership(forPath: "/tmp/ws/app")
    #expect(hit?.projectID == projectID)
    #expect(hit?.workspaceName == "ws")
    #expect(manager.workspaceMembership(forPath: "/tmp/ws") == nil)
  }

  @Test
  func builtinEnvCarriesTheWorkspaceRootOnlyInsideAWorkspace() {
    let inside = HierarchyManager.injectingBuiltins(
      ["CODANS_WORKSPACE_ROOT": "stale"], worktreePath: "/tmp/ws/app", rootPath: "/tmp/ws",
      workspaceRoot: "/tmp/ws")
    #expect(inside[BuiltinEnvVar.workspaceRoot.key] == "/tmp/ws")
    #expect(inside[BuiltinEnvVar.rootPath.key] == "/tmp/ws")
    let outside = HierarchyManager.injectingBuiltins(
      ["CODANS_WORKSPACE_ROOT": "stale"], worktreePath: "/tmp/p", rootPath: "/tmp/p")
    #expect(outside[BuiltinEnvVar.workspaceRoot.key] == nil)
    #expect(BuiltinEnvVar.reservedKeys.contains("CODANS_WORKSPACE_ROOT"))
  }

  @Test
  func manifestSetterIsTransient() {
    let projectID = manager.addProject(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    let manifest = WorkspaceManifest(title: "Checkout Flow")
    manager.setProjectWorkspaceManifest(projectID: projectID, manifest: manifest)
    #expect(manager.catalog.projects[0].workspace == manifest)
  }
}
