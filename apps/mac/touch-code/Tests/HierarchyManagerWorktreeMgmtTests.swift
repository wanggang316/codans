import Foundation
import Testing
import TouchCodeCore

@testable import touch_code

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
  func archiveTearsDownSurfaces() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    let tabID = try manager.createTab(
      in: worktreeID, in: projectID, name: nil
    )
    let paneID = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    fakeRuntime.reset()
    fakeRuntime.livePaneIDs.insert(paneID)

    try manager.setWorktreeArchived(worktreeID: worktreeID, archived: true)
    #expect(fakeRuntime.closeSurfaceCalls == [paneID])
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

  /// In-place branch update (HAN-62). When the user runs `git checkout`
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
  /// prefix (what T-PROJECT's canonicalized `Project.rootPath` holds
  /// after `resolvingSymlinksInPath()`). The directory itself is real;
  /// `resolvingSymlinksInPath()` only walks symlinks for existing
  /// components, so tests that need both forms to canonicalize to the
  /// same string must go through a real on-disk path.
  private static func makeAliasedTempDir(tag: String) throws -> (varForm: String, privateForm: String, url: URL) {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appending(
      path: "touch-code-wt-\(tag)-\(UUID().uuidString)", directoryHint: .isDirectory
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
    // On macOS `/var` is a symlink to `/private/var`; T-PROJECT's
    // Project.rootPath goes through resolvingSymlinksInPath() and ends
    // up in the `/private/var/...` form, while `wt ls --json` emits
    // the unresolved `/var/...` form. Reconcile must canonicalize
    // both sides so the main checkout doesn't duplicate.
    let alias = try Self.makeAliasedTempDir(tag: "reconcile")
    defer { try? FileManager.default.removeItem(at: alias.url) }
    // Catalog stores the resolved form, matching T-PROJECT's side.
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
    // PR #31 review M2: Worktree.path must land in the catalog in the
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
    let projectID = manager.addProject(
      name: "p", rootPath: canonicalForm, gitRoot: canonicalForm
    )
    // Feeding the `/var/...` alias must still store the canonical form.
    let wtIDFromVar = try manager.createWorktree(
      in: projectID, name: "from-var",
      path: alias.varForm, branch: "from-var"
    )
    let storedFromVar = manager.catalog.projects[0].worktrees
      .first(where: { $0.id == wtIDFromVar })?.path
    #expect(storedFromVar == canonicalForm)

    // Feeding the `/private/var/...` alias stores the same canonical.
    let wtIDFromPrivate = try manager.createWorktree(
      in: projectID, name: "from-private",
      path: alias.privateForm, branch: "from-private"
    )
    let storedFromPrivate = manager.catalog.projects[0].worktrees
      .first(where: { $0.id == wtIDFromPrivate })?.path
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
  func reconcileTearsDownPanesOnAutoArchive() throws {
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
    let paneID = try manager.openPane(
      in: tabID, in: staleID, in: projectID,
      workingDirectory: "/repo/stale", initialCommand: nil
    )
    fakeRuntime.reset()
    fakeRuntime.livePaneIDs.insert(paneID)
    _ = manager.reconcileDiscoveredWorktrees(
      projectID: projectID,
      entries: [(path: "/repo", branch: "main")]
    )
    #expect(fakeRuntime.closeSurfaceCalls == [paneID])
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

  // MARK: - runningPaneCount

  @Test
  func runningPaneCountReflectsRuntime() throws {
    let projectID = manager.addProject(
      name: "p", rootPath: "/repo", gitRoot: "/repo"
    )
    let worktreeID = try manager.createWorktree(
      in: projectID, name: "feature", path: "/repo/feat", branch: "feature"
    )
    let tabID = try manager.createTab(
      in: worktreeID, in: projectID, name: nil
    )
    let paneA = try manager.openPane(
      in: tabID, in: worktreeID, in: projectID,
      workingDirectory: "/repo/feat", initialCommand: nil
    )
    let paneB = try manager.splitPane(
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

  // MARK: - createWorktree uniqueness (HAN-82)

  /// Repeated `tc worktree new` calls for the same `(project, path)`
  /// used to silently add a fresh row each time (see HAN-82). The
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
  /// HAN-82 reproduction had every retry use the same display name.
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
  /// downstream `tc tab new` failure) sets `reuseExisting` to ask
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
}
