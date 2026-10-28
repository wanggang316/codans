import CodansCore
import Foundation
import Testing

@testable import Codans

/// End-to-end reconcile of a Workspace against real git and real manifests:
/// the version 1 manifest migrates, default links appear, migrated rows keep
/// their identity across reconcile and reload, and live git facts refresh
/// rows in place.
@MainActor
struct HierarchyClientWorkspaceReconcileTests {
  private struct Fixture {
    let base: URL
    let catalogURL: URL
    let rootPath: String
    let sourcePath: String
    let memberPath: String

    func cleanUp() {
      try? FileManager.default.removeItem(at: base)
    }
  }

  @discardableResult
  private func git(_ arguments: [String], cwd: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(bytes: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw TestError.git(arguments.joined(separator: " "), output)
    }
    return output
  }

  private enum TestError: Error {
    case git(String, String)
  }

  /// A source repository and a version 1 Workspace whose `app` entry is a
  /// worktree of it on `feat/x`. The Workspace root sits inside an outer
  /// repository, the layout where a git probe of the root would go wrong.
  private func makeFixture() throws -> Fixture {
    let raw = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ws-reconcile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    let base = URL(fileURLWithPath: HierarchyManager.canonicalPath(raw.path), isDirectory: true)
    let commit = ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m"]
    try git(["init", "-q", "-b", "main"], cwd: base.path)
    try git(commit + ["outer"], cwd: base.path)

    let sourcePath = base.appendingPathComponent("src-app").path
    try FileManager.default.createDirectory(atPath: sourcePath, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], cwd: sourcePath)
    try git(commit + ["init"], cwd: sourcePath)

    let rootPath = base.appendingPathComponent("ws").path
    try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
    let memberPath = (rootPath as NSString).appendingPathComponent("app")
    try git(["worktree", "add", "-q", "-b", "feat/x", memberPath, "main"], cwd: sourcePath)
    try WorkspaceManifestStore.save(
      WorkspaceManifest(
        title: "ws",
        repositories: [WorkspaceManifest.Entry(name: "app", sourceGitRoot: sourcePath)]),
      rootPath: rootPath)
    return Fixture(
      base: base, catalogURL: base.appendingPathComponent("catalog.json"), rootPath: rootPath,
      sourcePath: sourcePath, memberPath: memberPath)
  }

  /// A version 3 Workspace (root row with a tab, one child row) after the
  /// catalog migration, as `CatalogStore.load` hands it over.
  private func migratedCatalog(_ fx: Fixture) -> Catalog {
    let pane = Pane(tabs: [Tab(name: "agent", content: .terminal(workingDirectory: fx.rootPath))])
    let root = Worktree(
      name: "ws", path: fx.rootPath, splitTree: SplitTree(leaf: pane.id), panes: [pane], focusedPaneID: pane.id)
    let child = Worktree(name: "app", path: fx.memberPath, branch: "feat/x", sourceGitRoot: fx.sourcePath)
    let workspace = Project(
      name: "ws", rootPath: fx.rootPath, worktrees: [root, child], selectedWorktreeID: root.id,
      isWorkspace: true)
    return CatalogMigrationV3ToV4.migrate(Catalog(projects: [workspace]))
  }

  /// The manager's store is detached: a debounced save that fires after
  /// `cleanUp()` would create the fixture directory again. The reload test
  /// writes the catalog itself.
  private func makeClient(_ catalog: Catalog) -> (HierarchyClient, HierarchyManager) {
    let manager = HierarchyManager(
      catalog: catalog, store: CatalogStore.detached(), runtime: FakeHierarchyRuntime())
    return (HierarchyClient.live(manager: manager), manager)
  }

  private func row(_ manager: HierarchyManager, path: String) -> Worktree? {
    manager.catalog.projects.first?.worktrees.first {
      $0.path == HierarchyManager.canonicalPath(path)
    }
  }

  @Test
  func migratedWorkspaceKeepsRowIdentityThroughReconcileAndReload() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let catalog = migratedCatalog(fx)
    let before = catalog.projects[0]
    let (client, manager) = makeClient(catalog)

    await client.reconcileDiscoveredWorktrees(before.id)

    let defaultDir = (fx.rootPath as NSString).appendingPathComponent("default")
    #expect(FileManager.default.fileExists(atPath: WorkspaceLayout.groupsManifestURL(rootPath: fx.rootPath).path))
    #expect(
      (try? FileManager.default.destinationOfSymbolicLink(
        atPath: (defaultDir as NSString).appendingPathComponent("src-app"))) == fx.sourcePath)
    let project = try #require(manager.catalog.projects.first)
    #expect(project.gitRoot == nil)
    #expect(project.workspace?.title == "ws")
    #expect(project.workspaceGroups.map(\.id) == before.workspaceGroups.map(\.id))
    #expect(project.selectedWorktreeID == before.worktrees[0].id)
    for old in before.worktrees {
      let now = try #require(project.worktrees.first { $0.id == old.id })
      #expect(now.path == old.path)
      #expect(now.panes == old.panes)
      #expect(now.workspaceSlot == old.workspaceSlot)
    }
    let defaultGroupID = before.workspaceGroups[0].id
    #expect(
      row(manager, path: defaultDir)?.workspaceSlot == WorkspaceSlot(groupID: defaultGroupID, role: .groupTerminal))
    let reference = try #require(row(manager, path: fx.sourcePath))
    #expect(reference.workspaceSlot == WorkspaceSlot(groupID: defaultGroupID, role: .reference))
    #expect(reference.branch == "main")
    #expect(project.worktrees.count == 4)
    #expect(client.workspaceMembership(fx.memberPath)?.projectID == project.id)
    #expect(client.workspaceMembership(fx.sourcePath) == nil)

    // Repeat reconcile changes nothing.
    let settled = manager.catalog
    await client.reconcileDiscoveredWorktrees(before.id)
    #expect(manager.catalog == settled)

    // Reload from disk, as a relaunch does, and reconcile again.
    try CatalogStore(fileURL: fx.catalogURL).saveNow(manager.catalog)
    let reloaded = try CatalogStore(fileURL: fx.catalogURL).load()
    let (client2, manager2) = makeClient(reloaded)
    await client2.reconcileDiscoveredWorktrees(before.id)
    let relaunched = try #require(manager2.catalog.projects.first)
    #expect(relaunched.worktrees.map(\.id) == project.worktrees.map(\.id))
    #expect(relaunched.worktrees.map(\.workspaceSlot) == project.worktrees.map(\.workspaceSlot))
    #expect(relaunched.workspaceGroups == project.workspaceGroups)
  }

  @Test
  func memberBranchSwitchRefreshesBranchInPlace() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let (client, manager) = makeClient(migratedCatalog(fx))
    let projectID = try #require(manager.catalog.projects.first).id
    await client.reconcileDiscoveredWorktrees(projectID)
    let memberID = try #require(row(manager, path: fx.memberPath)).id

    try git(["checkout", "-q", "-b", "fix/y"], cwd: fx.memberPath)
    await client.reconcileDiscoveredWorktrees(projectID)

    let member = try #require(row(manager, path: fx.memberPath))
    #expect(member.id == memberID)
    #expect(member.branch == "fix/y")
    #expect(member.name == "app")
  }

  @Test
  func missingSourceKeepsTheReferenceAndMissingMemberIsArchived() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let (client, manager) = makeClient(migratedCatalog(fx))
    let projectID = try #require(manager.catalog.projects.first).id
    await client.reconcileDiscoveredWorktrees(projectID)
    let referenceID = try #require(row(manager, path: fx.sourcePath)).id

    try FileManager.default.removeItem(atPath: fx.memberPath)
    try FileManager.default.moveItem(atPath: fx.sourcePath, toPath: fx.sourcePath + "-moved")
    await client.reconcileDiscoveredWorktrees(projectID)

    let project = try #require(manager.catalog.projects.first)
    let reference = try #require(project.worktrees.first { $0.id == referenceID })
    #expect(!reference.archived)
    #expect(project.unavailableWorkspaceRows == [referenceID])
    #expect(row(manager, path: fx.memberPath)?.archived == true)
  }

  @Test
  func newerGroupManifestFailsTheProjectWithoutReconcile() async throws {
    let fx = try makeFixture()
    defer { fx.cleanUp() }
    let url = WorkspaceLayout.groupsManifestURL(rootPath: fx.rootPath)
    try Data(#"{"schemaVersion": 3, "title": "ws", "projects": [], "groups": []}"#.utf8).write(to: url)
    let (client, manager) = makeClient(migratedCatalog(fx))
    let before = manager.catalog.projects[0].worktrees

    await ProjectReconciler(client: client).reconcileAll(force: true)

    let project = try #require(manager.catalog.projects.first)
    #expect(project.loadState == .failed(reason: "Created by a newer Codans"))
    #expect(project.worktrees == before)
    #expect(!FileManager.default.fileExists(atPath: (fx.rootPath as NSString).appendingPathComponent("default")))
  }
}
