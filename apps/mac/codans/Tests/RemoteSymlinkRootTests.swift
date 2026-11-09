import CodansCore
import Foundation
import Testing

@testable import Codans

/// #402: a Remote Project whose root goes through a symlink on the host
/// (`/tmp` → `/private/tmp` on macOS) must list its main worktree once. The
/// host's git decides the root's form; this Mac's filesystem never does.
struct RemoteSymlinkRootTests {
  private static let host = RemoteHost(alias: "mini", port: 2396)
  private static let entered = "/tmp/linko"
  private static let resolved = "/private/tmp/linko"
  private static let sha = "f00dcafe00000000000000000000000000000000"

  @MainActor
  private static func makeManager() -> HierarchyManager {
    HierarchyManager(
      catalog: .default,
      store: CatalogStore(
        fileURL: FileManager.default.temporaryDirectory.appending(component: UUID().uuidString + ".json")),
      runtime: FakeHierarchyRuntime()
    )
  }

  /// What the host's `git worktree list --porcelain` reports for the repo.
  private static var hostEntries: [(path: String, branch: String?, head: String?)] {
    [
      (path: resolved, branch: "feat/header-redesign", head: sha),
      (path: "/private/tmp/linko-main", branch: "main", head: sha),
    ]
  }

  @MainActor
  private static func reconcile(_ manager: HierarchyManager, _ projectID: ProjectID) {
    manager.reconcileDiscoveredWorktrees(
      projectID: projectID, entries: hostEntries, normalizePath: HierarchyManager.normalizeRemotePath)
  }

  @MainActor
  private static func mainRows(_ manager: HierarchyManager) -> [Worktree] {
    let project = manager.catalog.projects[0]
    return project.worktrees.filter { !$0.archived && $0.branch == "feat/header-redesign" }
  }

  @Test
  @MainActor
  func stringOnlyReconcileDuplicatesTheMainCheckoutOfASymlinkedRoot() {
    // The cause: the entered root and the host-resolved path differ as
    // strings, so the main checkout is appended next to the root's row.
    let manager = Self.makeManager()
    let projectID = manager.addRemoteProject(name: "linko", remoteHost: Self.host, rootPath: Self.entered)
    manager.setProjectGitRoot(projectID: projectID, gitRoot: Self.resolved)
    Self.reconcile(manager, projectID)
    let paths = manager.catalog.projects[0].worktrees.map(\.path)
    #expect(paths.contains(Self.entered) && paths.contains(Self.resolved))
  }

  @Test
  @MainActor
  func symlinkedGitRootListsTheMainCheckoutOnceAcrossReconciles() {
    let manager = Self.makeManager()
    let projectID = manager.addRemoteProject(
      name: "linko", remoteHost: Self.host, rootPath: Self.entered, gitRoot: Self.resolved)

    #expect(manager.adoptCanonicalRemoteRoot(projectID: projectID, canonicalRoot: Self.resolved) == .adopted)
    Self.reconcile(manager, projectID)
    #expect(manager.catalog.projects[0].rootPath == Self.resolved)
    #expect(Self.mainRows(manager).count == 1)
    #expect(manager.catalog.projects[0].worktrees.count == 2)
    let project = manager.catalog.projects[0]
    #expect(project.childWorktrees.first.map(project.isMainCheckout) == true)

    // A later reconcile: the host still answers the same root, nothing changes.
    #expect(manager.adoptCanonicalRemoteRoot(projectID: projectID, canonicalRoot: Self.resolved) == .unchanged)
    Self.reconcile(manager, projectID)
    #expect(Self.mainRows(manager).count == 1)
    #expect(manager.catalog.projects[0].worktrees.count == 2)
  }

  @Test
  @MainActor
  func symlinkedFolderThatBecomesARepoKeepsOneRow() {
    // A folder Project seeds a synthetic row at the entered root; once the
    // host has a repo there, that row becomes the main checkout.
    let manager = Self.makeManager()
    let projectID = manager.addRemoteProject(name: "linko", remoteHost: Self.host, rootPath: Self.entered)
    let syntheticID = manager.catalog.projects[0].worktrees[0].id

    #expect(manager.adoptCanonicalRemoteRoot(projectID: projectID, canonicalRoot: Self.resolved) == .adopted)
    manager.setProjectGitRoot(projectID: projectID, gitRoot: Self.resolved)
    Self.reconcile(manager, projectID)

    let rows = Self.mainRows(manager)
    #expect(rows.map(\.id) == [syntheticID])
    #expect(rows.first?.path == Self.resolved)
  }

  @Test
  @MainActor
  func existingDuplicateMergesIntoTheFirstRowKeepingTabs() throws {
    let manager = Self.makeManager()
    let projectID = manager.addRemoteProject(name: "linko", remoteHost: Self.host, rootPath: Self.entered)
    manager.setProjectGitRoot(projectID: projectID, gitRoot: Self.entered)
    Self.reconcile(manager, projectID)
    let before = manager.catalog.projects[0].worktrees
    let original = try #require(before.first { $0.path == Self.entered })
    let duplicate = try #require(before.first { $0.path == Self.resolved })
    let originalTab = try manager.createTab(in: original.id, in: projectID, name: "a")
    let duplicateTab = try manager.createTab(in: duplicate.id, in: projectID, name: "b")
    manager.setWorktreePinned(worktreeID: duplicate.id, isPinned: true)
    try manager.selectWorktree(duplicate.id, in: projectID)

    #expect(manager.adoptCanonicalRemoteRoot(projectID: projectID, canonicalRoot: Self.resolved) == .adopted)
    Self.reconcile(manager, projectID)

    let project = manager.catalog.projects[0]
    #expect(project.gitRoot == Self.resolved)
    let rows = project.worktrees.filter { $0.path == Self.resolved }
    #expect(rows.map(\.id) == [original.id])
    #expect(rows.first?.tabs.map(\.id) == [originalTab, duplicateTab])
    #expect(rows.first?.isPinned == true)
    #expect(rows.first?.branch == "feat/header-redesign")
    #expect(project.selectedWorktreeID == original.id)
    // The removed row was the selected one, so its active tab stays active.
    #expect(rows.first?.selectedTabID == duplicateTab)
    #expect(project.worktrees.count == 2)
  }

  @Test
  @MainActor
  func mergeKeepsTheKeptRowsActiveTabWhenItWasSelected() throws {
    let manager = Self.makeManager()
    let projectID = manager.addRemoteProject(name: "linko", remoteHost: Self.host, rootPath: Self.entered)
    manager.setProjectGitRoot(projectID: projectID, gitRoot: Self.entered)
    Self.reconcile(manager, projectID)
    let before = manager.catalog.projects[0].worktrees
    let original = try #require(before.first { $0.path == Self.entered })
    let duplicate = try #require(before.first { $0.path == Self.resolved })
    let originalTab = try manager.createTab(in: original.id, in: projectID, name: "a")
    _ = try manager.createTab(in: duplicate.id, in: projectID, name: "b")
    try manager.selectWorktree(original.id, in: projectID)

    #expect(manager.adoptCanonicalRemoteRoot(projectID: projectID, canonicalRoot: Self.resolved) == .adopted)

    let kept = manager.catalog.projects[0].worktrees.first { $0.id == original.id }
    #expect(kept?.selectedTabID == originalTab)
    #expect(manager.catalog.projects[0].selectedWorktreeID == original.id)
  }

  @Test
  @MainActor
  func rootOwnedByAnotherProjectOnTheHostIsNotAdopted() {
    // ADR 0006: two Projects on one Host never share a root. When the host
    // form of this root is already another Project's root, the root stays.
    let manager = Self.makeManager()
    let entered = manager.addRemoteProject(
      name: "linko", remoteHost: Self.host, rootPath: Self.entered, gitRoot: Self.resolved)
    let owner = manager.addRemoteProject(
      name: "linko", remoteHost: Self.host, rootPath: Self.resolved, gitRoot: Self.resolved)
    let before = manager.catalog

    #expect(manager.adoptCanonicalRemoteRoot(projectID: entered, canonicalRoot: Self.resolved) == .conflict(owner))
    #expect(manager.catalog == before)
    #expect(manager.adoptCanonicalRemoteRoot(projectID: owner, canonicalRoot: Self.resolved) == .unchanged)
  }

  @Test
  @MainActor
  func conflictStillMergesTheExistingDuplicateUnderTheKeptRoot() throws {
    // Case-insensitive host: the Project entered as `repo` already has a
    // duplicate row at git's `Repo`, and a second Project was added as `Repo`.
    // The root stays (ADR 0006), but the two rows for one folder merge.
    let typed = "/data/repo"
    let onDisk = "/data/Repo"
    let manager = Self.makeManager()
    let projectID = manager.addRemoteProject(name: "repo", remoteHost: Self.host, rootPath: typed)
    manager.setProjectGitRoot(projectID: projectID, gitRoot: typed)
    manager.reconcileDiscoveredWorktrees(
      projectID: projectID, entries: [(path: onDisk, branch: "main", head: Self.sha)],
      normalizePath: HierarchyManager.normalizeRemotePath)
    let before = manager.catalog.projects[0].worktrees
    let original = try #require(before.first { $0.path == typed })
    let duplicate = try #require(before.first { $0.path == onDisk })
    let originalTab = try manager.createTab(in: original.id, in: projectID, name: "a")
    let duplicateTab = try manager.createTab(in: duplicate.id, in: projectID, name: "b")
    let owner = manager.addRemoteProject(name: "Repo", remoteHost: Self.host, rootPath: onDisk, gitRoot: onDisk)
    let ownerBefore = manager.catalog.projects[1]

    #expect(manager.adoptCanonicalRemoteRoot(projectID: projectID, canonicalRoot: onDisk) == .conflict(owner))

    let project = manager.catalog.projects[0]
    #expect(project.rootPath == typed)
    #expect(project.gitRoot == typed)
    #expect(project.worktrees.map(\.id) == [original.id])
    #expect(project.worktrees.first?.path == typed)
    #expect(project.worktrees.first?.tabs.map(\.id) == [originalTab, duplicateTab])
    #expect(manager.catalog.projects[1] == ownerBefore)

    // A later reconcile finds nothing more to merge.
    let merged = manager.catalog
    #expect(manager.adoptCanonicalRemoteRoot(projectID: projectID, canonicalRoot: onDisk) == .conflict(owner))
    #expect(manager.catalog == merged)
  }

  @Test
  @MainActor
  func sameRootOnAnotherHostIsNoConflict() {
    let manager = Self.makeManager()
    let projectID = manager.addRemoteProject(
      name: "linko", remoteHost: Self.host, rootPath: Self.entered, gitRoot: Self.resolved)
    _ = manager.addRemoteProject(
      name: "linko", remoteHost: RemoteHost(alias: "other"), rootPath: Self.resolved, gitRoot: Self.resolved)
    _ = manager.addProject(name: "linko", rootPath: Self.resolved, gitRoot: Self.resolved)

    #expect(manager.adoptCanonicalRemoteRoot(projectID: projectID, canonicalRoot: Self.resolved) == .adopted)
    #expect(manager.catalog.projects[0].rootPath == Self.resolved)
  }

  @Test
  @MainActor
  func nonSymlinkedRootIsUnchanged() {
    let manager = Self.makeManager()
    let projectID = manager.addRemoteProject(
      name: "app", remoteHost: Self.host, rootPath: "/srv/app", gitRoot: "/srv/app")
    let before = manager.catalog
    #expect(manager.adoptCanonicalRemoteRoot(projectID: projectID, canonicalRoot: "/srv/app") == .unchanged)
    #expect(manager.adoptCanonicalRemoteRoot(projectID: projectID, canonicalRoot: "/srv/app/") == .unchanged)
    #expect(manager.catalog == before)
  }

  @Test
  @MainActor
  func localProjectIsNeverRekeyed() {
    let manager = Self.makeManager()
    let projectID = manager.addProject(name: "app", rootPath: "/srv/app", gitRoot: "/srv/app")
    #expect(manager.adoptCanonicalRemoteRoot(projectID: projectID, canonicalRoot: "/private/srv/app") == .unchanged)
    #expect(manager.catalog.projects[0].rootPath == "/srv/app")
  }

  // MARK: - Host probe

  @Test
  func probeRunsOnTheHostAndSkipsLoginBanners() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(
        code: 0, stdout: Data("Welcome\n/private/tmp/linko\n".utf8), stderr: Data(), stdoutOverflow: false)
    ])
    let service = RemoteGitService(host: Self.host, runner: runner)
    let root = await service.canonicalWorkTreeRoot(of: Self.entered)
    #expect(root == Self.resolved)
    let call = await runner.calls[0]
    #expect(call.arguments.contains(SSHCommand.sshExecutablePath))
    #expect(call.arguments.last?.contains("rev-parse") == true)
    #expect(call.arguments.last?.contains(Self.entered) == true)
  }

  @Test
  func probeFailureAnswersNil() async {
    let runner = RecordingCommandRunner(outcomes: [
      .exited(code: 1, stdout: Data("Welcome\n".utf8), stderr: Data(), stdoutOverflow: false)
    ])
    let service = RemoteGitService(host: Self.host, runner: runner)
    #expect(await service.canonicalWorkTreeRoot(of: Self.entered) == nil)
  }

  @Test
  func workTreeRootScriptAnswersGitsFormOnlyForTheRoot() throws {
    // The script runs under POSIX sh on the host; local /bin/sh and git
    // match that contract, so exercise it for real.
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("codans-wtr-\(UUID().uuidString)")
    let repo = base.appendingPathComponent("Repo")
    let link = base.appendingPathComponent("link")
    let plain = base.appendingPathComponent("plain")
    try fm.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try fm.createDirectory(at: plain, withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: link, withDestinationURL: repo)
    defer { try? fm.removeItem(at: base) }

    func run(_ executable: String, _ arguments: [String]) -> (status: Int32, stdout: String) {
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: executable)
      proc.arguments = arguments
      let out = Pipe()
      proc.standardOutput = out
      proc.standardError = Pipe()
      try? proc.run()
      proc.waitUntilExit()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
    func probe(_ path: String) -> (status: Int32, stdout: String) {
      run("/bin/sh", ["-c", RemoteGitService.workTreeRootScript, "sh", path])
    }
    #expect(run("/usr/bin/git", ["init", "-q", repo.path]).status == 0)
    let gitTop = run("/usr/bin/git", ["-C", repo.path, "rev-parse", "--show-toplevel"])
      .stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    let viaLink = probe(link.path)
    #expect(viaLink.status == 0)
    #expect(RemoteGitService.lastNonEmptyLine(of: viaLink.stdout) == gitTop)
    #expect(!gitTop.contains("link"))

    #expect(probe(repo.appendingPathComponent("sub").path).status != 0)
    #expect(probe(plain.path).status != 0)
    #expect(probe(base.appendingPathComponent("missing").path).status != 0)
  }
}
