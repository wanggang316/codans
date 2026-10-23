import CodansCore
import Foundation
import Testing

@testable import Codans

/// Group deletion and Workspace removal through the `WorkspaceClient` seam:
/// real git, a real `CatalogStore`, and `FakeHierarchyRuntime`.
@MainActor
struct WorkspaceGroupDeletionTests {
  /// A Workspace with sources `app` and `lib`, the `default` group, and the
  /// named group `fix` whose members `fix/app` and `fix/lib` are on
  /// `fix/login` (created by the group).
  struct Layout {
    let fx: WorkspaceClientFixture
    let projectID: ProjectID
    let root: String
    let app: String
    let lib: String
    let defaultID: WorkspaceGroupID
    let fixID: WorkspaceGroupID

    var fixDirectory: String { (root as NSString).appendingPathComponent("fix") }
    var fixApp: String { (root as NSString).appendingPathComponent("fix/app") }
    var fixLib: String { (root as NSString).appendingPathComponent("fix/lib") }
    var defaultDirectory: String { (root as NSString).appendingPathComponent("default") }

    func manifest() throws -> WorkspaceGroupsManifest {
      try WorkspaceManifestStore.loadGroups(rootPath: root)
    }
  }

  /// Fails `removeWorktree` for the paths in `failing`, so a test can force
  /// a partial failure and then clear it for the retry.
  final class RemovalFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var failing: Set<String> = []

    func set(_ paths: Set<String>) {
      lock.lock()
      failing = paths
      lock.unlock()
    }

    func shouldFail(_ path: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return failing.contains(path)
    }
  }

  static func makeGit(failures: RemovalFailures) -> GitWorktreeClient {
    var git = GitWorktreeClient.makeLive()
    let remove = git.removeWorktree
    git.removeWorktree = { repoRoot, path in
      if failures.shouldFail(HierarchyManager.canonicalPath(path.path(percentEncoded: false))) {
        throw GitWorktreeError.commandFailed(command: "git worktree remove", stderr: "injected failure")
      }
      try await remove(repoRoot, path)
    }
    return git
  }

  func makeLayout(
    _ fx: WorkspaceClientFixture,
    createdBranch: Bool = true,
    extraGroups: (_ app: String, _ lib: String, _ root: String) throws -> [WorkspaceGroupsManifest.Group] = { _, _, _ in
      []
    }
  ) async throws -> Layout {
    let app = try fx.makeRepo(named: "src/app")
    let lib = try fx.makeRepo(named: "src/lib")
    let root = fx.path("ws")
    try fx.addCheckout(of: app, at: "\(root)/fix/app", branch: "fix/login")
    try fx.addCheckout(of: lib, at: "\(root)/fix/lib", branch: "fix/login")
    let defaultID = WorkspaceGroupID()
    let fixID = WorkspaceGroupID()
    let manifest = WorkspaceGroupsManifest(
      title: "ws",
      projects: [.init(name: "app", sourceGitRoot: app), .init(name: "lib", sourceGitRoot: lib)],
      groups: [
        .init(id: defaultID, name: "default", kind: .default, path: "default"),
        .init(
          id: fixID, name: "fix", kind: .named, path: "fix", branch: "fix/login",
          members: [
            .init(
              id: WorkspaceMemberID(), name: "app", path: "fix/app", sourceGitRoot: app,
              branch: "fix/login", createdBranch: createdBranch),
            .init(
              id: WorkspaceMemberID(), name: "lib", path: "fix/lib", sourceGitRoot: lib,
              branch: "fix/login", createdBranch: createdBranch),
          ]),
      ] + (try extraGroups(app, lib, root)))
    let projectID = try await fx.registerWorkspace(manifest, rootPath: root)
    return Layout(
      fx: fx, projectID: projectID, root: root, app: app, lib: lib, defaultID: defaultID, fixID: fixID)
  }

  func branches(in repo: String, _ fx: WorkspaceClientFixture) throws -> [String] {
    try fx.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd: repo)
      .split(separator: "\n").map(String.init)
  }

  func busyPane(in row: Worktree, _ layout: Layout) async throws -> PaneID {
    let manager = layout.fx.manager
    let tabID = try manager.createTab(in: row.id, in: layout.projectID, name: nil)
    let paneID = try await manager.openPane(
      in: tabID, in: row.id, in: layout.projectID, workingDirectory: row.path, initialCommand: nil)
    manager.setPaneCommandBusy(paneID, true)
    return paneID
  }

  // MARK: Check

  @Test
  func cleanGroupHasNoRisksAndListsCreatedBranches() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)

    let check = await fx.client.checkGroupDeletion(layout.projectID, layout.fixID)

    #expect(check.groupName == "fix")
    #expect(!check.hasRisks)
    #expect(!check.isBlocked)
    #expect(check.members.map(\.name) == ["app", "lib"])
    #expect(check.members.map(\.branch) == ["fix/login", "fix/login"])
    #expect(check.members.map(\.deletableBranches) == [["fix/login"], ["fix/login"]])
    #expect(check.members[0].worktreeID == (try fx.row(in: layout.projectID, at: layout.fixApp)).id)
  }

  @Test
  func checkReportsEachRiskPerProject() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)
    try "x".write(toFile: "\(layout.fixApp)/scratch.txt", atomically: true, encoding: .utf8)
    try fx.commit("local work", in: layout.fixLib)
    try "notes".write(toFile: "\(layout.fixDirectory)/notes.md", atomically: true, encoding: .utf8)
    let groupRow = try fx.row(in: layout.projectID, at: layout.fixDirectory)
    let pane = try await busyPane(in: groupRow, layout)

    let check = await fx.client.checkGroupDeletion(layout.projectID, layout.fixID)

    #expect(check.hasRisks)
    #expect(!check.isBlocked)
    #expect(check.members.map(\.uncommittedCount) == [1, 0])
    #expect(check.members.map(\.unpushedCount) == [0, 1])
    #expect(check.busyPaneIDs == [pane])
    #expect(check.extraEntries == ["notes.md"])
  }

  @Test
  func unpushedCountsCommitsAheadOfTheUpstream() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)
    try fx.makeOrigin(for: layout.app, named: "origin/app.git")
    try fx.git(["push", "-q", "-u", "origin", "fix/login"], cwd: layout.fixApp)
    try fx.commit("one", in: layout.fixApp)
    try fx.commit("two", in: layout.fixApp)

    let check = await fx.client.checkGroupDeletion(layout.projectID, layout.fixID)

    #expect(check.members.first?.unpushedCount == 2)
  }

  @Test
  func branchesTheGroupDidNotCreateAreNotDeletable() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx, createdBranch: false)

    let check = await fx.client.checkGroupDeletion(layout.projectID, layout.fixID)

    #expect(check.members.map(\.deletableBranches) == [[], []])
  }

  @Test
  func branchCheckedOutElsewhereOrDefaultIsNotDeletable() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)
    // `lib` checks the member branch out a second time; `app`'s member moves
    // to the repository default branch (`origin/HEAD`), which no other
    // worktree has checked out.
    try fx.git(["worktree", "add", "-q", "-f", fx.path("elsewhere"), "fix/login"], cwd: layout.lib)
    try fx.makeOrigin(for: layout.app, named: "origin/app.git")
    try fx.git(["remote", "set-head", "origin", "main"], cwd: layout.app)
    try fx.git(["checkout", "-q", "--detach"], cwd: layout.app)
    try fx.git(["checkout", "-q", "main"], cwd: layout.fixApp)

    let check = await fx.client.checkGroupDeletion(layout.projectID, layout.fixID)

    #expect(check.members.map(\.branch) == ["main", "fix/login"])
    #expect(check.members.map(\.deletableBranches) == [[], []])
  }

  @Test
  func failedProbeBlocksTheDelete() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)
    try "gitdir: /nonexistent\n".write(toFile: "\(layout.fixLib)/.git", atomically: true, encoding: .utf8)

    let check = await fx.client.checkGroupDeletion(layout.projectID, layout.fixID)

    #expect(check.isBlocked)
    #expect(check.members.first { $0.name == "lib" }?.checkFailure != nil)
    await #expect(throws: WorkspaceError.checkFailed(check)) {
      _ = try await fx.client.deleteGroup(
        layout.projectID, layout.fixID, GroupDeletionRequest(acknowledgeRisks: true))
    }
    #expect(fx.isDirectory(layout.fixApp))
  }

  // MARK: Delete

  @Test
  func deleteWithoutAcknowledgmentThrowsWithTheCheck() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)
    try "x".write(toFile: "\(layout.fixApp)/scratch.txt", atomically: true, encoding: .utf8)
    let check = await fx.client.checkGroupDeletion(layout.projectID, layout.fixID)

    await #expect(throws: WorkspaceError.risksNotAcknowledged(check)) {
      _ = try await fx.client.deleteGroup(layout.projectID, layout.fixID, GroupDeletionRequest())
    }
    #expect(fx.exists("\(layout.fixApp)/scratch.txt"))
    #expect(fx.project(layout.projectID)?.workspaceGroups.first { $0.id == layout.fixID }?.deletion == nil)
  }

  @Test
  func defaultGroupCannotBeDeleted() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)

    await #expect(throws: WorkspaceError.cannotDeleteDefault) {
      _ = try await fx.client.deleteGroup(
        layout.projectID, layout.defaultID, GroupDeletionRequest(acknowledgeRisks: true))
    }
    #expect(await fx.client.checkGroupDeletion(layout.projectID, layout.defaultID).isBlocked)
  }

  @Test
  func deleteRemovesCheckoutsBranchesDirectoryAndRows() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)
    try "notes".write(toFile: "\(layout.fixDirectory)/notes.md", atomically: true, encoding: .utf8)
    let appTip = try fx.tip("HEAD", in: layout.app)
    let memberRow = try fx.row(in: layout.projectID, at: layout.fixApp)
    _ = try await busyPane(in: memberRow, layout)

    let outcome = try await fx.client.deleteGroup(
      layout.projectID, layout.fixID, GroupDeletionRequest(deleteBranches: true, acknowledgeRisks: true))

    #expect(outcome.deletedGroup)
    #expect(outcome.removedMembers == ["app", "lib"])
    #expect(outcome.deletedBranches == ["fix/login", "fix/login"])
    #expect(outcome.failures.isEmpty)
    #expect(!fx.exists(layout.fixDirectory))
    #expect(try branches(in: layout.app, fx) == ["main"])
    #expect(try branches(in: layout.lib, fx) == ["main"])
    #expect(try fx.tip("HEAD", in: layout.app) == appTip)
    #expect(try layout.manifest().groups.map(\.id) == [layout.defaultID])
    let project = try #require(fx.project(layout.projectID))
    #expect(project.workspaceGroups.map(\.id) == [layout.defaultID])
    #expect(!project.worktrees.contains { $0.workspaceSlot?.groupID == layout.fixID })
    #expect(fx.manager.workspaceGroupBusyPanes(projectID: layout.projectID, groupID: layout.fixID).isEmpty)
    // Sources and default links are untouched.
    #expect(fx.isDirectory("\(layout.app)/.git"))
    let link = try FileManager.default.destinationOfSymbolicLink(atPath: "\(layout.defaultDirectory)/app")
    #expect(link == layout.app)
  }

  @Test
  func deleteKeepsBranchesUnlessAsked() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)

    let outcome = try await fx.client.deleteGroup(layout.projectID, layout.fixID, GroupDeletionRequest())

    #expect(outcome.deletedGroup)
    #expect(outcome.deletedBranches.isEmpty)
    #expect(try branches(in: layout.app, fx).contains("fix/login"))
  }

  @Test
  func partialFailureKeepsTheFailedMemberAndRetryFinishes() async throws {
    let failures = RemovalFailures()
    let fx = try WorkspaceClientFixture(gitWorktreeClient: Self.makeGit(failures: failures))
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)
    failures.set([layout.fixLib])
    let libRow = try fx.row(in: layout.projectID, at: layout.fixLib)

    let first = try await fx.client.deleteGroup(
      layout.projectID, layout.fixID, GroupDeletionRequest(deleteBranches: true, acknowledgeRisks: true))

    #expect(!first.deletedGroup)
    #expect(first.removedMembers == ["app"])
    #expect(first.failures.map(\.name) == ["lib"])
    #expect(first.failures.first?.path == layout.fixLib)
    #expect(!fx.exists(layout.fixApp))
    #expect(fx.isDirectory(layout.fixLib))
    let manifestGroup = try #require(try layout.manifest().groups.first { $0.id == layout.fixID })
    #expect(manifestGroup.members.map(\.name) == ["lib"])
    #expect(manifestGroup.deletion?.deleteBranches == true)
    let record = try #require(fx.project(layout.projectID)?.workspaceGroups.first { $0.id == layout.fixID })
    #expect(record.deletion?.deleteBranches == true)
    #expect(try fx.row(in: layout.projectID, at: layout.fixLib).id == libRow.id)
    #expect(throws: (any Error).self) { try fx.row(in: layout.projectID, at: layout.fixApp) }
    // A reconcile (or relaunch) keeps the incomplete state.
    await fx.hierarchy.reconcileDiscoveredWorktrees(layout.projectID)
    #expect(fx.project(layout.projectID)?.workspaceGroups.first { $0.id == layout.fixID }?.deletion != nil)

    failures.set([])
    let retry = try await fx.client.deleteGroup(
      layout.projectID, layout.fixID, GroupDeletionRequest(deleteBranches: true, acknowledgeRisks: true))

    #expect(retry.deletedGroup)
    #expect(retry.removedMembers == ["lib"])
    #expect(!fx.exists(layout.fixDirectory))
    #expect(try branches(in: layout.lib, fx) == ["main"])
    #expect(fx.project(layout.projectID)?.workspaceGroups.map(\.id) == [layout.defaultID])
  }

  @Test
  func deletingTheMigratedGroupKeepsRootStateAndOtherGroups() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let existingID = WorkspaceGroupID()
    let layout = try await makeLayout(fx) { app, _, root in
      try fx.addCheckout(of: app, at: "\(root)/app", branch: "feat/old")
      return [
        .init(
          id: existingID, name: "existing", kind: .named, path: ".", origin: .migrated,
          members: [.init(id: WorkspaceMemberID(), name: "app", path: "app", sourceGitRoot: app, branch: "feat/old")])
      ]
    }
    let rootRow = try fx.row(in: layout.projectID, at: layout.root)
    #expect(rootRow.workspaceSlot == WorkspaceSlot(groupID: existingID, role: .groupTerminal))

    let outcome = try await fx.client.deleteGroup(
      layout.projectID, existingID, GroupDeletionRequest(deleteBranches: true, acknowledgeRisks: true))

    #expect(outcome.deletedGroup)
    #expect(!fx.exists("\(layout.root)/app"))
    #expect(fx.isDirectory(layout.root))
    #expect(fx.exists(WorkspaceLayout.groupsManifestURL(rootPath: layout.root).path(percentEncoded: false)))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: "\(layout.defaultDirectory)/app") == layout.app)
    #expect(fx.isDirectory(layout.fixApp))
    #expect(fx.isDirectory("\(layout.app)/.git"))
    // A migrated member records no created branch, so none is deleted.
    #expect(try branches(in: layout.app, fx).contains("feat/old"))
    #expect(try layout.manifest().groups.map(\.id) == [layout.defaultID, layout.fixID])
    #expect(throws: (any Error).self) { try fx.row(in: layout.projectID, at: layout.root) }
  }

  // MARK: Workspace removal

  @Test
  func sidebarOnlyRemovalKeepsTheDisk() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)

    let outcome = try await fx.client.removeWorkspace(layout.projectID, .sidebarOnly)

    #expect(!outcome.deletedFolder)
    #expect(fx.project(layout.projectID) == nil)
    #expect(fx.isDirectory(layout.fixApp))
    #expect(fx.isDirectory(layout.defaultDirectory))
  }

  @Test
  func deletingOwnedFilesRemovesTheRootAndKeepsSources() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)
    let appTip = try fx.tip("HEAD", in: layout.app)

    let outcome = try await fx.client.removeWorkspace(
      layout.projectID, .deleteOwnedFiles(GroupDeletionRequest(deleteBranches: true, acknowledgeRisks: true)))

    #expect(outcome.deletedFolder)
    #expect(outcome.failures.isEmpty)
    #expect(!fx.exists(layout.root))
    #expect(fx.project(layout.projectID) == nil)
    #expect(fx.isDirectory("\(layout.app)/.git"))
    #expect(fx.isDirectory("\(layout.lib)/.git"))
    #expect(try fx.tip("HEAD", in: layout.app) == appTip)
    #expect(try branches(in: layout.app, fx) == ["main"])
  }

  @Test
  func deletingOwnedFilesKeepsForeignRootFiles() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)
    try "keep".write(toFile: "\(layout.root)/README.md", atomically: true, encoding: .utf8)

    let outcome = try await fx.client.removeWorkspace(
      layout.projectID, .deleteOwnedFiles(GroupDeletionRequest(acknowledgeRisks: true)))

    #expect(!outcome.deletedFolder)
    #expect(outcome.failures.isEmpty)
    #expect(fx.project(layout.projectID) == nil)
    #expect(fx.exists("\(layout.root)/README.md"))
    #expect(!fx.exists(layout.fixDirectory))
    #expect(!fx.exists(layout.defaultDirectory))
  }

  @Test
  func deletingOwnedFilesNeedsAcknowledgment() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)
    try "x".write(toFile: "\(layout.fixApp)/scratch.txt", atomically: true, encoding: .utf8)
    let check = await fx.client.checkGroupDeletion(layout.projectID, layout.fixID)

    await #expect(throws: WorkspaceError.risksNotAcknowledged(check)) {
      _ = try await fx.client.removeWorkspace(layout.projectID, .deleteOwnedFiles(GroupDeletionRequest()))
    }
    #expect(fx.project(layout.projectID) != nil)
    #expect(fx.isDirectory(layout.fixApp))
  }

  @Test
  func partialWorkspaceDeletionKeepsTheEntryAndTheFailedGroup() async throws {
    let failures = RemovalFailures()
    let fx = try WorkspaceClientFixture(gitWorktreeClient: Self.makeGit(failures: failures))
    defer { fx.cleanUp() }
    let layout = try await makeLayout(fx)
    failures.set([layout.fixLib])

    let outcome = try await fx.client.removeWorkspace(
      layout.projectID, .deleteOwnedFiles(GroupDeletionRequest(acknowledgeRisks: true)))

    #expect(!outcome.deletedFolder)
    #expect(outcome.failures.count == 1)
    let project = try #require(fx.project(layout.projectID))
    #expect(project.workspaceGroups.first { $0.id == layout.fixID }?.deletion != nil)
    #expect(fx.isDirectory(layout.fixLib))
    #expect(fx.isDirectory(layout.defaultDirectory))
    #expect(fx.isDirectory(layout.root))
  }
}
