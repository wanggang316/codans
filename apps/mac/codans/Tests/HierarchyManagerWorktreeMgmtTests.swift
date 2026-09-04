import CodansCore
import Foundation
import Testing

@testable import Codans

/// Covers the three new Worktree-Management-era additions on
/// `HierarchyManager`: `setWorktreeArchived`,
/// `reconcileDiscoveredWorktrees`, and `runningPaneCount`.
///
/// Each test builds a fresh manager + fake runtime per `init`, matching
/// the pattern in `HierarchyManagerTests.swift`.
@MainActor
struct HierarchyManagerWorktreeMgmtTests {
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

  // MARK: - setWorktreeArchived

  @Test
  func archiveTogglesFlag() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: true)
    let worktree = manager.catalog.projects[0].worktrees.first { $0.id == worktreeID }
    #expect(worktree?.archived == true)
  }

  // MARK: - archivedAt + auto-delete due (Cleanup)

  @Test
  func archiveStampsArchivedAtAndUnarchiveClearsIt() throws {
    let projectID = manager.addProject(name: "p", rootPath: "/repo", gitRoot: "/repo")
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: true)
    #expect(manager.catalog.projects[0].worktrees.first { $0.id == worktreeID }?.archivedAt != nil)

    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: false)
    #expect(manager.catalog.projects[0].worktrees.first { $0.id == worktreeID }?.archivedAt == nil)
  }

  @Test
  func archivedWorktreesDueReturnsExpiredAndExcludesFresh() throws {
    let projectID = manager.addProject(name: "p", rootPath: "/repo", gitRoot: "/repo")
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: true)

    // ttl = 7 days. Evaluated "now" only 1 hour after archiving → not due.
    let oneHourLater = Date().addingTimeInterval(3_600)
    #expect(manager.archivedWorktreesDue(in: projectID, now: oneHourLater, ttl: 7 * 86_400).isEmpty)

    // Evaluated 8 days later → past the 7-day retention → due.
    let eightDaysLater = Date().addingTimeInterval(8 * 86_400)
    #expect(
      manager.archivedWorktreesDue(in: projectID, now: eightDaysLater, ttl: 7 * 86_400) == [worktreeID]
    )
  }

  @Test
  func archivedWorktreesDueBackfillsMissingTimestampInsteadOfDeleting() {
    // A pre-existing archived row with no recorded timestamp (catalog from
    // before `archivedAt` existed) must NOT be deleted retroactively; the
    // sweep back-fills its timestamp so it ages from first observation.
    let stale = Worktree(
      name: "old", path: "/repo/old", branch: "old", archived: true, archivedAt: nil
    )
    let project = Project(name: "p", rootPath: "/repo", gitRoot: "/repo", worktrees: [stale])
    let seeded = HierarchyManager(
      catalog: Catalog(projects: [project]), store: store, runtime: fakeRuntime
    )

    let due = seeded.archivedWorktreesDue(in: project.id, now: Date(), ttl: 1)
    #expect(due.isEmpty)
    #expect(seeded.catalog.projects[0].worktrees[0].archivedAt != nil)
  }

  @Test
  func archiveIsIdempotent() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: false)
    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: false)
    let worktree = manager.catalog.projects[0].worktrees.first { $0.id == worktreeID }
    #expect(worktree?.archived == false)
  }

  @Test
  func archiveMainCheckoutThrows() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    // addProject with gitRoot != nil does not synthesize a worktree;
    // create one whose path EQUALS the Project rootPath to simulate the
    // main checkout discovered by reconcile.
    let mainID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    #expect(throws: HierarchyError.self) {
      try manager.setWorktreeArchived(worktreeID: mainID, archived: true)
    }
  }

  @Test
  func archiveSuspendsPanesKeepsThemAndAnnounces() async throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    let tabID = try manager.createTab(
      in: worktreeID, in: projectID, name: nil
    )
    let paneID = try await manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    fakeRuntime.reset()
    fakeRuntime.livePaneIDs.insert(paneID)

    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: true)

    // Archive routes through suspendSurface (kills the daemon, emits no
    // .paneExited) — NOT closeSurface, whose .paneExited would route through
    // paneLifecycleExited → closePane and delete the Pane.
    #expect(fakeRuntime.suspendSurfaceCalls == [paneID])
    #expect(fakeRuntime.closeSurfaceCalls.isEmpty)
    // Soft-hide keeps the Pane in the catalog for restore.
    let worktree = manager.catalog.projects[0].worktrees.first { $0.id == worktreeID }
    #expect(worktree?.archived == true)
    #expect(worktree?.tabs.flatMap { $0.panes }.map(\.id) == [paneID])
    // One structural-mutation announce so the AgentState reconcile runs
    // against visiblePaneIDs() and retires the hidden worktree's rows.
    #expect(fakeRuntime.announceHierarchyMutatedCount == 1)
  }

  @Test
  func archiveClearsBusySetsSoTheRunControlDoesNotStickOnRunning() async throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)
    let paneID = try await manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    let scriptID = UUID()
    manager.setRunScriptPane(worktreeID: worktreeID, scriptID: scriptID, paneID: paneID)
    manager.setPaneCommandBusy(paneID, true)
    manager.setLastFocusedPane(paneID, in: tabID)
    #expect(manager.isScriptRunning(worktreeID: worktreeID, scriptID: scriptID))

    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: true)

    // Soft-hide keeps the Pane in the catalog, so `isScriptRunning`'s
    // "catalog.pane is gone" guard cannot retire the entry — only clearing
    // the busy set does. Archive already killed the daemon, so a control
    // still reading "running" here would never resolve, even on unarchive.
    #expect(!manager.isScriptRunning(worktreeID: worktreeID, scriptID: scriptID))
    #expect(!manager.paneIsBusy(paneID))
    #expect(manager.lastFocusedPane(in: tabID) == nil)
  }

  @Test
  func archiveAdvancesSelectionWhenItPointsAtTheArchivedRow() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let mainID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let featureID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    try manager.selectWorktree(featureID, in: projectID)
    #expect(manager.catalog.projects[0].selectedWorktreeID == featureID)

    try manager.setWorktreeArchived(worktreeID: featureID, archived: true)
    #expect(manager.catalog.projects[0].selectedWorktreeID == mainID)
  }

  @Test
  func archiveLeavesSelectionAloneWhenItPointsElsewhere() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let mainID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let featureID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    try manager.selectWorktree(mainID, in: projectID)

    try manager.setWorktreeArchived(worktreeID: featureID, archived: true)
    #expect(manager.catalog.projects[0].selectedWorktreeID == mainID)
  }

  @Test
  func archiveDropsSelectionWhenNoOtherVisibleWorktreeRemains() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let onlyID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    try manager.selectWorktree(onlyID, in: projectID)

    try manager.setWorktreeArchived(worktreeID: onlyID, archived: true)
    #expect(manager.catalog.projects[0].selectedWorktreeID == nil)
  }

  @Test
  func unarchiveDoesNotDisturbSelection() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let mainID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let featureID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    try manager.setWorktreeArchived(worktreeID: featureID, archived: true)
    try manager.selectWorktree(mainID, in: projectID)

    try manager.setWorktreeArchived(worktreeID: featureID, archived: false)
    #expect(manager.catalog.projects[0].selectedWorktreeID == mainID)
  }

  // MARK: - removeWorktree selection advance

  @Test
  func removeAdvancesSelectionToFirstNonArchivedSibling() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let mainID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let archivedID = try manager.createWorktree(
      in: projectID, name: "archived", path: "/repo/archived", branch: "archived"
    )
    let activeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    try manager.setWorktreeArchived(worktreeID: archivedID, archived: true)
    try manager.selectWorktree(activeID, in: projectID)

    try manager.removeWorktree(activeID, from: projectID)
    // `mainID` is `worktrees.first { !$0.archived }` after the remove —
    // before this fix the fallback would have picked `archivedID`.
    #expect(manager.catalog.projects[0].selectedWorktreeID == mainID)
  }

  // MARK: - reconcileDiscoveredWorktrees

  @Test
  func reconcileWithNothingStaleDoesNotAnnounce() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    fakeRuntime.reset()

    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID, entries: [(path: "/repo", branch: "main")]
    )

    #expect(fakeRuntime.announceHierarchyMutatedCount == 0)
  }

  @Test
  func removeWorktreeAnnouncesAndClearsBusySets() async throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    let tabID = try manager.createTab(in: worktreeID, in: projectID, name: nil)
    let paneID = try await manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    manager.setPaneCommandBusy(paneID, true)
    manager.setLastFocusedPane(paneID, in: tabID)
    fakeRuntime.reset()

    try manager.removeWorktree(worktreeID, from: projectID)

    // `closeSurface` emits `.paneExited` only for Panes that had a live
    // surface, so a Worktree of never-opened Panes would otherwise leave the
    // membership reconcilers with no signal at all.
    #expect(fakeRuntime.announceHierarchyMutatedCount == 1)
    #expect(!manager.paneIsBusy(paneID))
    #expect(manager.lastFocusedPane(in: tabID) == nil)
  }

  @Test
  func reconcileAppendsUnknownEntries() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let appended = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [
        (path: "/repo", branch: "main"),
        (path: "/repo/feature", branch: "feature"),
      ]
    )
    #expect(appended == 1)
    #expect(manager.catalog.projects[0].worktrees.count == 2)
  }

  @Test
  func reconcileIsIdempotent() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let entries: [(path: String, branch: String?)] = [
      (path: "/repo", branch: "main"),
      (path: "/repo/feature", branch: "feature"),
    ]
    let first = manager.reconcileDiscoveredWorktrees(
      projectID: projectID, entries: entries
    )
    let second = manager.reconcileDiscoveredWorktrees(
      projectID: projectID, entries: entries
    )
    #expect(first == 2)
    #expect(second == 0)
    #expect(manager.catalog.projects[0].worktrees.count == 2)
  }

  /// Dir-Project transitions to a git repo: `addProject(gitRoot: nil)`
  /// seeded a synthetic placeholder Worktree with `branch == nil` and
  /// `name == lastPathComponent`. Once `git init` lands and discovery
  /// reports the same canonical path with a real branch, reconcile must
  /// upgrade the placeholder in place (same id, no extra row) so the
  /// sidebar reads "main" instead of the folder name.
  @Test
  func reconcileUpgradesSyntheticPlaceholderOnDirToRepoTransition() {
    let projectID = manager.addProject(
      name: "scratch", rootPath: "/scratch", gitRoot: nil
    )
    let originalWorktree = manager.catalog.projects[0].worktrees[0]
    #expect(originalWorktree.name == "scratch")
    #expect(originalWorktree.branch == nil)

    manager.setProjectGitRoot(projectID: projectID, gitRoot: "/scratch")
    let appended = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [(path: "/scratch", branch: "main")]
    )

    #expect(appended == 0)
    #expect(manager.catalog.projects[0].worktrees.count == 1)
    let upgraded = manager.catalog.projects[0].worktrees[0]
    #expect(upgraded.id == originalWorktree.id)
    #expect(upgraded.name == "main")
    #expect(upgraded.branch == "main")
  }

  /// In-place branch update. When the user runs `git checkout`
  /// inside a worktree pane, the next reconcile pass surfaces the new
  /// branch. The catalog row must follow HEAD so the sidebar subtitle,
  /// WorktreeHeader, and GitHub PR fetch all observe the new value.
  /// Row id, tabs, and other flags are preserved (in-place mutation).
  @Test
  func reconcileUpdatesBranchOnExistingWorktreeAfterCheckout() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    // Simulate `git checkout other-branch` inside `/repo/feat`.
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [
        (path: "/repo", branch: "main"),
        (path: "/repo/feat", branch: "other-branch"),
      ]
    )
    let updated = manager.catalog.projects[0].worktrees.first { $0.id == worktreeID }
    #expect(updated?.branch == "other-branch")
    // `name` was tracking the old branch, so it follows along.
    #expect(updated?.name == "other-branch")
    // Row identity preserved — no extra row, no archive.
    #expect(manager.catalog.projects[0].worktrees.count == 2)
    #expect(updated?.archived == false)
  }

  /// Custom display name (e.g. created via `createWorktreeWithGit` with
  /// `displayName: "feat/web-ui"`, `branch: "feat-web-ui"`) must survive
  /// a branch change. Reconcile updates `branch` but leaves `name` alone
  /// because it was never tracking `branch` to begin with.
  @Test
  func reconcilePreservesCustomDisplayNameAcrossBranchChange() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feat/web-ui", path: "/repo/feat", branch: "feat-web-ui"
    )
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [
        (path: "/repo", branch: "main"),
        (path: "/repo/feat", branch: "other-branch"),
      ]
    )
    let updated = manager.catalog.projects[0].worktrees.first { $0.id == worktreeID }
    #expect(updated?.branch == "other-branch")
    #expect(updated?.name == "feat/web-ui")
  }

  /// Detached HEAD: reconcile reports `branch == nil`. The catalog row
  /// drops its branch but keeps its display name so the sidebar still
  /// renders something readable instead of a blank row.
  @Test
  func reconcileClearsBranchOnDetachedHead() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [
        (path: "/repo", branch: "main"),
        (path: "/repo/feat", branch: nil),
      ]
    )
    let updated = manager.catalog.projects[0].worktrees.first { $0.id == worktreeID }
    #expect(updated?.branch == nil)
    #expect(updated?.name == "feature")
  }

  /// Produces `(varForm, privateForm)` — two aliased paths to the same
  /// on-disk directory, one with the `/var/folders/...` prefix (what
  /// `wt ls --json` emits) and one with the `/private/var/folders/...`
  /// prefix (what the project's canonicalized `Project.rootPath` holds
  /// after `resolvingSymlinksInPath()`). The directory itself is real;
  /// `resolvingSymlinksInPath()` only walks symlinks for existing
  /// components, so tests that need both forms to canonicalize to the
  /// same string must go through a real on-disk path.
  private static func makeAliasedTempDir(tag: String) throws -> (varForm: String, privateForm: String, url: URL) {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appending(
      path: "codans-wt-\(tag)-\(UUID().uuidString)", directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // `temporaryDirectory.path` is already in `/var/folders/...` form on
    // macOS (symlink prefix). The `/private/...` alias is a simple
    // string prefix transform.
    let varForm = dir.path
    let privateForm =
      varForm.hasPrefix("/private")
      ? varForm
      : "/private" + varForm
    return (varForm, privateForm, dir)
  }

  @Test
  func reconcileDedupesSymlinkAliases() throws {
    // On macOS `/var` is a symlink to `/private/var`; the project's
    // Project.rootPath goes through resolvingSymlinksInPath() and ends
    // up in the `/private/var/...` form, while `wt ls --json` emits
    // the unresolved `/var/...` form. Reconcile must canonicalize
    // both sides so the main checkout doesn't duplicate.
    let alias = try Self.makeAliasedTempDir(tag: "reconcile")
    defer { try? FileManager.default.removeItem(at: alias.url) }
    // Catalog stores the resolved form, matching the project's side.
    let projectID = manager.addProject(
      name: "p", rootPath: alias.privateForm, gitRoot: alias.privateForm
    )
    _ = try manager.createWorktree(
      in: projectID, name: "main",
      path: alias.privateForm, branch: "main"
    )
    // Reconcile feeds the un-resolved form (what `wt ls --json` would
    // produce for a repo discovered under /var).
    let appended = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [(path: alias.varForm, branch: "main")]
    )
    #expect(appended == 0)
    #expect(manager.catalog.projects[0].worktrees.count == 1)
  }

  @Test
  func createWorktreeStoresCanonicalizedPath() throws {
    // Worktree.path must land in the catalog in the
    // canonical form that HierarchyManager.canonicalPath produces, so
    // view-layer direct string comparisons against the also-canonical
    // Project.rootPath (main-checkout guard etc.) stay correct under
    // symlink aliases like /var ↔ /private/var.
    //
    // The canonical form depends on the OS's symlink table (on some
    // macOS configs resolvingSymlinksInPath collapses to /var/..., on
    // others to /private/var/...); the test asserts the invariant
    // `stored == canonicalPath(input)` for BOTH input aliases rather
    // than hardcoding which side wins.
    let alias = try Self.makeAliasedTempDir(tag: "createwt")
    defer { try? FileManager.default.removeItem(at: alias.url) }
    let canonicalForm = HierarchyManager.canonicalPath(alias.varForm)
    #expect(canonicalForm == HierarchyManager.canonicalPath(alias.privateForm))

    // The two aliases canonicalize to the same path, and the per-project
    // uniqueness guard forbids two worktrees at one canonical path — so
    // exercise each alias in its own project. Both must store the canonical
    // form regardless of which alias was fed in.
    let projectVar = manager.addProject(
      name: "pv", rootPath: canonicalForm, gitRoot: canonicalForm
    )
    let wtIDFromVar = try manager.createWorktree(
      in: projectVar, name: "from-var",
      path: alias.varForm, branch: "from-var"
    )
    let storedFromVar = manager.catalog.projects
      .first(where: { $0.id == projectVar })?
      .worktrees.first(where: { $0.id == wtIDFromVar })?.path
    #expect(storedFromVar == canonicalForm)

    let projectPrivate = manager.addProject(
      name: "pp", rootPath: canonicalForm, gitRoot: canonicalForm
    )
    let wtIDFromPrivate = try manager.createWorktree(
      in: projectPrivate, name: "from-private",
      path: alias.privateForm, branch: "from-private"
    )
    let storedFromPrivate = manager.catalog.projects
      .first(where: { $0.id == projectPrivate })?
      .worktrees.first(where: { $0.id == wtIDFromPrivate })?.path
    #expect(storedFromPrivate == canonicalForm)
  }

  @Test
  func canonicalPathResolvesSymlinksForExistingPaths() throws {
    // resolvingSymlinksInPath() follows symlinks for existing path
    // components. Both aliases of the same on-disk temp dir must
    // collapse to identical canonical strings.
    let alias = try Self.makeAliasedTempDir(tag: "canonical")
    defer { try? FileManager.default.removeItem(at: alias.url) }

    let canonicalVar = HierarchyManager.canonicalPath(alias.varForm)
    let canonicalPrivate = HierarchyManager.canonicalPath(alias.privateForm)
    #expect(canonicalVar == canonicalPrivate)
    // Idempotent: re-canonicalizing is a no-op.
    #expect(HierarchyManager.canonicalPath(canonicalVar) == canonicalVar)
  }

  @Test
  func reconcileAutoArchivesStaleRows() throws {
    // Worktrees deleted outside the app (`git worktree remove`) drop out
    // of `wt ls --json`; reconcile soft-archives them so the sidebar's
    // non-archived filter hides them and clicks no longer reach a stale
    // cwd. Rows are kept in the catalog so Archived menu can restore.
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let staleID = try manager.createWorktree(
      in: projectID, name: "stale", path: "/repo/stale", branch: "stale"
    )
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [(path: "/repo", branch: "main")]
    )
    let worktrees = manager.catalog.projects[0].worktrees
    #expect(worktrees.count == 2)
    let stale = worktrees.first { $0.id == staleID }
    #expect(stale?.archived == true)
  }

  @Test
  func reconcileNeverArchivesMainCheckout() throws {
    // The main checkout (path == project.rootPath) cannot be archived
    // (setWorktreeArchived throws). Reconcile must skip it even when
    // `entries` is empty (e.g. transient git error) so the user is
    // never locked out of their primary worktree.
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let mainID = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID, entries: []
    )
    let main = manager.catalog.projects[0].worktrees
      .first { $0.id == mainID }
    #expect(main?.archived == false)
  }

  @Test
  func reconcilePreservesPinnedStaleRows() throws {
    // Pinned rows encode explicit user intent; reconcile leaves them
    // alone even when stale. The openPane defensive guard handles the
    // click-on-stale case without losing the pin.
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let pinnedID = try manager.createWorktree(
      in: projectID, name: "pinned", path: "/repo/pinned", branch: "pinned"
    )
    manager.setWorktreePinned(worktreeID: pinnedID, isPinned: true)
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [(path: "/repo", branch: "main")]
    )
    let pinned = manager.catalog.projects[0].worktrees
      .first { $0.id == pinnedID }
    #expect(pinned?.archived == false)
    #expect(pinned?.isPinned == true)
  }

  @Test
  func reconcileTearsDownPanesOnAutoArchive() async throws {
    // Stale-archive must release pty surfaces — same contract as the
    // user-invoked archive path. Without this, libghostty would hold
    // a working dir that no longer exists and fail on the next read.
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let staleID = try manager.createWorktree(
      in: projectID, name: "stale", path: "/repo/stale", branch: "stale"
    )
    let tabID = try manager.createTab(
      in: staleID, in: projectID, name: nil
    )
    let paneID = try await manager.openPane(
      in: tabID, in: staleID, in: projectID,
      workingDirectory: "/repo/stale", initialCommand: nil
    )
    manager.setPaneCommandBusy(paneID, true)
    fakeRuntime.reset()
    fakeRuntime.livePaneIDs.insert(paneID)
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [(path: "/repo", branch: "main")]
    )
    // Suspend, not close. This path archives, and `closeSurface`'s
    // `.paneExited` routes through `paneLifecycleExited` into `closeTab` /
    // `closePane`, deleting the very rows soft-hide keeps for restore. It
    // also left a never-opened Pane's daemon running.
    #expect(fakeRuntime.suspendSurfaceCalls == [paneID])
    #expect(fakeRuntime.closeSurfaceCalls.isEmpty)
    let stale = manager.catalog.projects[0].worktrees.first { $0.id == staleID }
    #expect(stale?.archived == true)
    #expect(stale?.tabs.flatMap { $0.panes }.map(\.id) == [paneID])
    #expect(!manager.paneIsBusy(paneID))
    // Auto-archive fires without the user asking, so a ghost row left behind
    // in the Agents View here is especially confusing.
    #expect(fakeRuntime.announceHierarchyMutatedCount == 1)
  }

  @Test
  func reconcileAutoArchiveIsIdempotent() throws {
    // A second reconcile pass with the same stale set must not flip
    // anything (already-archived guard) and must not schedule a save.
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "stale", path: "/repo/stale", branch: "stale"
    )
    let entries: [(path: String, branch: String?)] = [(path: "/repo", branch: "main")]
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID, entries: entries
    )
    let archivedAfterFirst = manager.catalog.projects[0].worktrees
      .filter(\.archived).count
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID, entries: entries
    )
    let archivedAfterSecond = manager.catalog.projects[0].worktrees
      .filter(\.archived).count
    #expect(archivedAfterFirst == 1)
    #expect(archivedAfterSecond == 1)
  }

  @Test
  func reconcileSkipsStaleSweepWhenDiscoveryIsEmpty() throws {
    // Regression (2026-08-25): a `git worktree list` that dies under disk
    // pressure surfaces here as a successful, well-formed, EMPTY response —
    // the bundled `wt ls --json` reads git through a process substitution, so
    // the child's non-zero exit is invisible to `set -euo pipefail` and the
    // script prints `[]` and exits 0. Sweeping on that archived every
    // non-pinned worktree across four projects while every directory was
    // still on disk. Zero entries means discovery failed, not that the repo
    // lost all its worktrees.
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let featureID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feature", branch: "feature"
    )
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID, entries: []
    )
    let feature = manager.catalog.projects[0].worktrees
      .first { $0.id == featureID }
    #expect(feature?.archived == false)
    #expect(manager.catalog.projects[0].worktrees.filter(\.archived).isEmpty)
  }

  @Test
  func reconcileKeepsPanesWhenDiscoveryIsEmpty() async throws {
    // The user-visible cost of sweeping on a failed discovery is not just the
    // hidden sidebar row — `closeSurface` tears down the pty, killing whatever
    // agent was running in it. Mirror of
    // `reconcileTearsDownPanesOnAutoArchive` for the untrusted-discovery path.
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "main", path: "/repo", branch: "main"
    )
    let featureID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feature", branch: "feature"
    )
    let tabID = try manager.createTab(
      in: featureID, in: projectID, name: nil
    )
    let paneID = try await manager.openPane(
      in: tabID, in: featureID, in: projectID,
      workingDirectory: "/repo/feature", initialCommand: nil
    )
    fakeRuntime.reset()
    fakeRuntime.livePaneIDs.insert(paneID)
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID, entries: []
    )
    #expect(fakeRuntime.closeSurfaceCalls.isEmpty)
  }

  // MARK: - runningPaneCount

  @Test
  func runningPaneCountReflectsRuntime() async throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    let tabID = try manager.createTab(
      in: worktreeID, in: projectID, name: nil
    )
    let paneA = try await manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    let paneB = try await manager.splitPane(
      paneA, direction: .right,
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    // Only paneA is live.
    fakeRuntime.livePaneIDs = [paneA]
    #expect(manager.runningPaneCount(worktreeID: worktreeID) == 1)
    // Both live.
    fakeRuntime.livePaneIDs = [paneA, paneB]
    #expect(manager.runningPaneCount(worktreeID: worktreeID) == 2)
    // None live.
    fakeRuntime.livePaneIDs = []
    #expect(manager.runningPaneCount(worktreeID: worktreeID) == 0)
  }

  @Test
  func runningPaneCountUnknownIDIsZero() {
    let unknown = WorktreeID()
    #expect(manager.runningPaneCount(worktreeID: unknown) == 0)
  }

  // MARK: - createWorktree uniqueness

  /// Repeated `codans worktree new` calls for the same `(project, path)`
  /// used to silently add a fresh row each time. The
  /// guard rejects the second call with `.invariantViolation` so the
  /// CLI hits exit 3 (conflict) instead of polluting the catalog.
  @Test
  func createWorktreeRejectsDuplicatePath() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "agent/HAN-79",
      path: "/repo/HAN-79", branch: "agent/HAN-79"
    )
    #expect(throws: HierarchyError.self) {
      try manager.createWorktree(
        in: projectID, name: "agent/HAN-79-alt",
        path: "/repo/HAN-79", branch: "agent/HAN-79"
      )
    }
    #expect(manager.catalog.projects[0].worktrees.count == 1)
  }

  /// Name collision (different path) also rejected — the dispatcher's
  /// reproduction had every retry use the same display name.
  @Test
  func createWorktreeRejectsDuplicateName() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "agent/HAN-79",
      path: "/repo/HAN-79", branch: "agent/HAN-79"
    )
    #expect(throws: HierarchyError.self) {
      try manager.createWorktree(
        in: projectID, name: "agent/HAN-79",
        path: "/repo/HAN-79-other", branch: "agent/HAN-79"
      )
    }
    #expect(manager.catalog.projects[0].worktrees.count == 1)
  }

  /// Symlink-aliased paths collide too — `/var/...` and
  /// `/private/var/...` resolve to the same canonical form, so a
  /// second create must trip the path guard even when the caller
  /// passes the un-resolved form.
  @Test
  func createWorktreeRejectsCanonicalAliasedPath() throws {
    let alias = try Self.makeAliasedTempDir(tag: "create-dup")
    defer { try? FileManager.default.removeItem(at: alias.url) }
    let projectID = manager.addProject(
      name: "p", rootPath: alias.privateForm, gitRoot: alias.privateForm
    )
    _ = try manager.createWorktree(
      in: projectID, name: "main",
      path: alias.privateForm, branch: "main"
    )
    #expect(throws: HierarchyError.self) {
      try manager.createWorktree(
        in: projectID, name: "second",
        path: alias.varForm, branch: "second"
      )
    }
    #expect(manager.catalog.projects[0].worktrees.count == 1)
  }

  /// Idempotent replay — caller (e.g. dispatcher recovering from a
  /// downstream `codans tab new` failure) sets `reuseExisting` to ask
  /// for the existing id back instead of a conflict.
  @Test
  func createWorktreeReuseExistingReturnsExistingID() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let first = try manager.createWorktree(
      in: projectID, name: "agent/HAN-79",
      path: "/repo/HAN-79", branch: "agent/HAN-79"
    )
    let second = try manager.createWorktree(
      in: projectID, name: "agent/HAN-79",
      path: "/repo/HAN-79", branch: "agent/HAN-79",
      reuseExisting: true
    )
    #expect(first == second)
    #expect(manager.catalog.projects[0].worktrees.count == 1)
  }

  /// `reuseExisting` only short-circuits on a canonical-path match;
  /// a same-name / different-path call must still be a conflict
  /// because two worktrees can't share a display name.
  @Test
  func createWorktreeReuseExistingStillRejectsNameOnlyCollision() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    _ = try manager.createWorktree(
      in: projectID, name: "agent/HAN-79",
      path: "/repo/HAN-79", branch: "agent/HAN-79"
    )
    #expect(throws: HierarchyError.self) {
      try manager.createWorktree(
        in: projectID, name: "agent/HAN-79",
        path: "/repo/HAN-79-other", branch: "agent/HAN-79",
        reuseExisting: true
      )
    }
    #expect(manager.catalog.projects[0].worktrees.count == 1)
  }

  /// Create-vs-reconcile race: a reconcile pulse adopted the freshly
  /// materialized worktree (name tracks branch), then the creation's
  /// finish path replays with `reuseExisting`. The adopted row's id
  /// comes back and the caller's display name — the user's original
  /// input — replaces the branch-tracking name.
  @Test
  func createWorktreeReuseExistingAdoptsCallerNameOnReconciledRow() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let appended = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [(path: "/repo/feat-web-ui", branch: "feat-web-ui")]
    )
    #expect(appended == 1)
    let adoptedID = manager.catalog.projects[0].worktrees
      .first { $0.path == "/repo/feat-web-ui" }?.id

    let replayed = try manager.createWorktree(
      in: projectID, name: "feat/web-ui",
      path: "/repo/feat-web-ui", branch: "feat-web-ui",
      reuseExisting: true
    )
    #expect(replayed == adoptedID)
    #expect(manager.catalog.projects[0].worktrees.count == 1)
    let row = manager.catalog.projects[0].worktrees.first { $0.id == replayed }
    #expect(row?.name == "feat/web-ui")
    #expect(row?.branch == "feat-web-ui")
  }

  /// A row whose name no longer tracks its branch was customized by the
  /// user; the `reuseExisting` replay must not rewrite it.
  @Test
  func createWorktreeReuseExistingKeepsCustomizedName() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "my custom name",
      path: "/repo/feat-x", branch: "feat-x"
    )
    let replayed = try manager.createWorktree(
      in: projectID, name: "feat/x",
      path: "/repo/feat-x", branch: "feat-x",
      reuseExisting: true
    )
    #expect(replayed == worktreeID)
    let row = manager.catalog.projects[0].worktrees.first { $0.id == replayed }
    #expect(row?.name == "my custom name")
  }
}
