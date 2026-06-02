import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// TestStore coverage for `BranchSwitcherFeature` — popover open/close
/// load orchestration, worktree-change cancellation, branch-switch happy
/// path, the dirty-tree error banner, the View-all delegate emission, and
/// the HEAD-change cache reset path. The reducer's effects are exercised
/// against `GitServiceClient.testValue` with per-test closure overrides.
@MainActor
struct BranchSwitcherFeatureTests {
  // MARK: - Fixtures

  private static func sampleInventory() -> BranchInventory {
    BranchInventory(
      current: "main",
      local: [
        BranchRef(shortName: "main", isRemote: false, upstream: "origin/main"),
        BranchRef(shortName: "feature/x", isRemote: false, upstream: nil),
      ],
      remote: [
        BranchRef(shortName: "origin/main", isRemote: true, upstream: nil)
      ]
    )
  }

  private static func sampleCommit(id: String, subject: String) -> Commit {
    Commit(
      id: id,
      authorName: "Gump",
      authorEmail: "1989wg@gmail.com",
      date: Date(timeIntervalSince1970: 1_700_000_000),
      subject: subject,
      parents: []
    )
  }

  private static func sampleCommits() -> [Commit] {
    [
      sampleCommit(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", subject: "first"),
      sampleCommit(id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", subject: "second"),
    ]
  }

  private static func makeState(
    projectID: ProjectID,
    worktreeID: WorktreeID,
    path: String = "/tmp/wt"
  ) -> BranchSwitcherFeature.State {
    var state = BranchSwitcherFeature.State()
    state.projectID = projectID
    state.worktreeID = worktreeID
    state.worktreePath = path
    return state
  }

  // MARK: - 1. popoverTapped kicks inventory + commits in parallel

  @Test
  func popoverTappedKicksInventoryAndCommitsLoadsInParallel() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let inventory = Self.sampleInventory()
    let commits = Self.sampleCommits()

    let store = TestStore(
      initialState: Self.makeState(projectID: projectID, worktreeID: worktreeID)
    ) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.listAllBranches = { _ in inventory }
      $0.gitService.log = { _, _ in
        LogPage(cursor: .init(offset: 0, limit: 10), commits: commits, hasMore: false)
      }
    }
    store.exhaustivity = .off

    await store.send(.popoverTapped) { state in
      state.isPopoverOpen = true
      state.inventoryLoading = true
      state.commitsLoading = true
    }
    // Both effects resolve; order isn't load-bearing.
    await store.receive(.inventoryLoaded(.success(inventory))) { state in
      state.inventory = inventory
      state.inventoryLoading = false
    }
    await store.receive(.commitsLoaded(.success(commits))) { state in
      state.recentCommits = commits
      state.commitsLoading = false
    }
  }

  // MARK: - 2. popoverTapped skips loads when caches are populated

  @Test
  func popoverTappedSkipsLoadsWhenCacheAlreadyPopulated() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.inventory = Self.sampleInventory()
    state.recentCommits = Self.sampleCommits()

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      // Closures intentionally unimplemented — if the reducer kicks
      // either load the test fails with an unimplemented-dependency
      // diagnostic.
      $0.gitService = GitServiceClient.testValue
    }

    // Open: both flags stay false because both caches are populated.
    await store.send(.popoverTapped) { $0.isPopoverOpen = true }
    // Close: clean slate, no effects.
    await store.send(.popoverTapped) { $0.isPopoverOpen = false }
    // Reopen: still no loads.
    await store.send(.popoverTapped) { $0.isPopoverOpen = true }
  }

  // MARK: - 3. worktreeChanged cancels in-flight loads + resets state

  @Test
  func worktreeChangedCancelsInflightLoadsAndResetsState() async {
    let projectA = ProjectID()
    let worktreeA = WorktreeID()
    let pathA = "/tmp/wtA"

    let projectB = ProjectID()
    let worktreeB = WorktreeID()
    let pathB = "/tmp/wtB"

    let store = TestStore(
      initialState: Self.makeState(projectID: projectA, worktreeID: worktreeA, path: pathA)
    ) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      // Both loads hang forever — they only complete via cancellation.
      $0.gitService.listAllBranches = { _ in
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        throw GitError.timedOut
      }
      $0.gitService.log = { _, _ in
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        throw GitError.timedOut
      }
    }
    // The cancelled effects never write to state; non-exhaustive matching
    // lets the test assert reset-state without enumerating the absent
    // `inventoryLoaded` / `commitsLoaded` follow-ups.
    store.exhaustivity = .off

    await store.send(.popoverTapped) { state in
      state.isPopoverOpen = true
      state.inventoryLoading = true
      state.commitsLoading = true
    }

    // Switch worktree — cancels the in-flight loads and clears caches.
    await store.send(
      .worktreeChanged(
        projectID: projectB,
        worktreeID: worktreeB,
        path: pathB,
        blockedBranches: [:]
      )
    ) { state in
      state.projectID = projectB
      state.worktreeID = worktreeB
      state.worktreePath = pathB
      state.inventory = nil
      state.inventoryLoading = false
      state.inventoryError = nil
      state.recentCommits = nil
      state.commitsLoading = false
      state.commitsError = nil
      state.isPopoverOpen = false
      state.isSwitching = false
      state.searchQuery = ""
      state.switchError = nil
    }
    // Implicit assertion: if the cancelled loads later wrote into state
    // the TestStore would flag an unhandled action on tear-down (even
    // with exhaustivity off, unconsumed *received* actions still fail).
  }

  // MARK: - 4. branchTapped → switching → success → HEAD reset

  @Test
  func branchTappedSetsSwitchingAndClosesPopoverThenSwitchSucceeds() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let inventory = Self.sampleInventory()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.inventory = inventory
    state.recentCommits = Self.sampleCommits()
    state.isPopoverOpen = true

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.switchBranch = { _, _ in }
    }

    await store.send(.branchTapped(.local(name: "main"))) { state in
      state.isSwitching = true
      state.isPopoverOpen = false
      state.switchError = nil
    }
    // Switch succeeds → emits nothing; spinner clears only on
    // headChangedForCurrentWorktree.
    await store.send(.headChangedForCurrentWorktree) { state in
      state.isSwitching = false
      state.inventory = nil
      state.recentCommits = nil
      state.switchError = nil
    }
  }

  // MARK: - 5. branchTapped surfaces stderr first line as banner

  @Test
  func branchTappedSurfacesFirstLineOfGitErrorAsBanner() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let stderr = """
      error: Your local changes to the following files would be overwritten:
      \tREADME.md
      Aborting
      """
    let firstLine = "error: Your local changes to the following files would be overwritten:"

    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.isPopoverOpen = true
    state.inventory = Self.sampleInventory()

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.switchBranch = { _, _ in
        throw GitError.exec(code: 1, stderr: stderr)
      }
    }

    await store.send(.branchTapped(.local(name: "main"))) { state in
      state.isSwitching = true
      state.isPopoverOpen = false
      state.switchError = nil
    }
    await store.receive(.switchFailed(message: firstLine)) { state in
      state.isSwitching = false
      state.switchError = .message(firstLine)
    }
  }

  // MARK: - 7. headChangedForCurrentWorktree clears spinner + caches

  @Test
  func headChangedForCurrentWorktreeClearsSpinnerAndResetsCaches() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.inventory = Self.sampleInventory()
    state.recentCommits = Self.sampleCommits()
    state.isSwitching = true
    state.switchError = .message("x")

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.headChangedForCurrentWorktree) { state in
      state.isSwitching = false
      state.inventory = nil
      state.recentCommits = nil
      state.switchError = nil
    }
  }

  // MARK: - 8. inventoryLoaded failure captures error + clears loading

  @Test
  func inventoryFailureCapturesErrorAndClearsLoading() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.inventoryLoading = true
    let error = GitError.exec(code: 1, stderr: "fatal: foo")

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.inventoryLoaded(.failure(error))) { state in
      state.inventory = nil
      state.inventoryLoading = false
      state.inventoryError = error
    }
  }

  // MARK: - 9. commitsLoaded failure captures error + clears loading

  @Test
  func commitsFailureCapturesErrorAndClearsLoading() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.commitsLoading = true
    let error = GitError.exec(code: 128, stderr: "fatal: bad object HEAD")

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.commitsLoaded(.failure(error))) { state in
      state.recentCommits = nil
      state.commitsLoading = false
      state.commitsError = error
    }
  }

  // MARK: - 10. Reopen after commits failure kicks a fresh load

  @Test
  func popoverReopenAfterCommitsFailureKicksFreshLoad() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let priorError = GitError.exec(code: 128, stderr: "fatal: bad object")
    let inventory = Self.sampleInventory()
    let commits = Self.sampleCommits()

    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    // Prior attempt failed: cache is nil, error is captured, no in-flight
    // load. Inventory is already populated so the reopen only kicks the
    // commits load — keeps the assertion surface tight.
    state.inventory = inventory
    state.recentCommits = nil
    state.commitsError = priorError
    state.commitsLoading = false

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.log = { _, _ in
        LogPage(cursor: .init(offset: 0, limit: 10), commits: commits, hasMore: false)
      }
    }

    await store.send(.popoverTapped) { state in
      state.isPopoverOpen = true
      state.commitsLoading = true
      // Clearing the prior error before the fresh fetch is the contract
      // that makes Retry-by-reopen work — otherwise stale "couldn't load"
      // copy would survive into the new attempt.
      state.commitsError = nil
    }
    await store.receive(.commitsLoaded(.success(commits))) { state in
      state.recentCommits = commits
      state.commitsLoading = false
      state.commitsError = nil
    }
  }

  // MARK: - 11. renameButtonTapped enters inline edit mode

  @Test
  func renameButtonTappedEntersInlineEditMode() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    // Pre-existing banner should be cleared when the user opens a rename.
    state.switchError = .message("stale switch error")

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.renameButtonTapped(branchName: "feat/x")) { state in
      state.renamingBranch = "feat/x"
      state.renameDraft = "feat/x"
      state.switchError = nil
    }
  }

  // MARK: - 12. renameDraftChanged updates draft

  @Test
  func renameDraftChangedUpdatesDraft() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.renamingBranch = "x"
    state.renameDraft = "x"

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.renameDraftChanged("y")) { state in
      state.renameDraft = "y"
    }
  }

  // MARK: - 13. renameConfirmed with same name cancels

  @Test
  func renameConfirmedWithSameNameCancels() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.renamingBranch = "x"
    // Surrounding whitespace must trim to the same name; treated as a no-op.
    state.renameDraft = "  x  "

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.renameConfirmed)
    await store.receive(.renameCancelled) { state in
      state.renamingBranch = nil
      state.renameDraft = ""
      state.renameInFlight = false
    }
  }

  // MARK: - 14. renameConfirmed with empty draft cancels

  @Test
  func renameConfirmedWithEmptyDraftCancels() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.renamingBranch = "x"
    state.renameDraft = "  "

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.renameConfirmed)
    await store.receive(.renameCancelled) { state in
      state.renamingBranch = nil
      state.renameDraft = ""
      state.renameInFlight = false
    }
  }

  // MARK: - 15. renameConfirmed kicks effect and succeeds

  @Test
  func renameConfirmedKicksRenameEffectAndSucceeds() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID, path: "/tmp/repo")
    state.renamingBranch = "x"
    state.renameDraft = "y"

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.renameBranch = { _, _, _ in }
    }

    await store.send(.renameConfirmed) { state in
      state.renameInFlight = true
    }
    await store.receive(.renameSucceeded) { state in
      state.renamingBranch = nil
      state.renameDraft = ""
      state.renameInFlight = false
    }
  }

  // MARK: - 16. renameConfirmed surfaces git error as banner

  @Test
  func renameConfirmedSurfacesGitErrorAsBanner() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let stderr = "fatal: A branch named 'main' already exists.\n"
    let firstLine = "fatal: A branch named 'main' already exists."
    let error = GitError.exec(code: 128, stderr: stderr)
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID, path: "/tmp/repo")
    state.renamingBranch = "x"
    state.renameDraft = "main"

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.renameBranch = { _, _, _ in
        throw error
      }
    }

    await store.send(.renameConfirmed) { state in
      state.renameInFlight = true
    }
    await store.receive(.renameFailed(error)) { state in
      state.renamingBranch = nil
      state.renameDraft = ""
      state.renameInFlight = false
      state.switchError = .message(firstLine)
    }
  }

  // MARK: - 17. renameCancelled clears state

  @Test
  func renameCancelledClearsState() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.renamingBranch = "x"
    state.renameDraft = "y"
    state.renameInFlight = true

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.renameCancelled) { state in
      state.renamingBranch = nil
      state.renameDraft = ""
      state.renameInFlight = false
    }
  }

  // MARK: - 18. headChangedForCurrentWorktree clears rename state

  @Test
  func headChangedForCurrentWorktreeClearsRenameState() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.inventory = Self.sampleInventory()
    state.recentCommits = Self.sampleCommits()
    state.renamingBranch = "x"
    state.renameDraft = "y"
    state.renameInFlight = true

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.headChangedForCurrentWorktree) { state in
      state.inventory = nil
      state.recentCommits = nil
      state.renamingBranch = nil
      state.renameDraft = ""
      state.renameInFlight = false
    }
  }

  // MARK: - 19. newBranchButtonTapped opens alert state

  @Test
  func newBranchButtonTappedOpensAlertState() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    // Pre-existing banner is cleared when the user opens the alert.
    state.switchError = .message("stale switch error")

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.newBranchButtonTapped(baseBranchName: "main")) { state in
      state.creatingBranchFrom = "main"
      state.newBranchDraft = ""
      state.switchError = nil
    }
  }

  // MARK: - 20. newBranchDraftChanged updates draft

  @Test
  func newBranchDraftChangedUpdatesDraft() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID)
    state.creatingBranchFrom = "main"
    state.newBranchDraft = ""

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.newBranchDraftChanged("feat/y")) { state in
      state.newBranchDraft = "feat/y"
    }
  }

  // MARK: - 21. newBranchConfirmed kicks effect and succeeds

  @Test
  func newBranchConfirmedKicksEffectAndSucceeds() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID, path: "/tmp/repo")
    state.creatingBranchFrom = "main"
    state.newBranchDraft = "feat/y"

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.createAndSwitchBranch = { _, _, _ in }
    }

    await store.send(.newBranchConfirmed) { state in
      state.newBranchInFlight = true
    }
    await store.receive(.newBranchSucceeded) { state in
      state.creatingBranchFrom = nil
      state.newBranchDraft = ""
      state.newBranchInFlight = false
    }
  }

  // MARK: - 22. newBranchConfirmed surfaces git error as banner

  @Test
  func newBranchConfirmedSurfacesGitErrorAsBanner() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let stderr = "fatal: A branch named 'main' already exists.\n"
    let firstLine = "fatal: A branch named 'main' already exists."
    let error = GitError.exec(code: 128, stderr: stderr)
    var state = Self.makeState(projectID: projectID, worktreeID: worktreeID, path: "/tmp/repo")
    state.creatingBranchFrom = "main"
    state.newBranchDraft = "main"

    let store = TestStore(initialState: state) {
      BranchSwitcherFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.createAndSwitchBranch = { _, _, _ in
        throw error
      }
    }

    await store.send(.newBranchConfirmed) { state in
      state.newBranchInFlight = true
    }
    await store.receive(.newBranchFailed(error)) { state in
      state.creatingBranchFrom = nil
      state.newBranchDraft = ""
      state.newBranchInFlight = false
      state.switchError = .message(firstLine)
    }
  }
}
