import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Tests for `DiffFeature` — covers the selection → changed-files load,
/// per-file diff load with cache, drawer-close cache survival, style
/// changes, and over-cap handling. The reducer's filesystem reads
/// (`String(contentsOf:)` for the working-tree side) are exercised against
/// a per-test temp directory so the cap-checking logic runs end-to-end
/// rather than via an additional injection seam.
@MainActor
struct DiffFeatureTests {
  // MARK: - Fixtures

  private static func makeTempWorktree(
    files: [String: String] = [:]
  ) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("DiffFeatureTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for (path, contents) in files {
      let fileURL = url.appendingPathComponent(path)
      try? FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    return url
  }

  private static func sampleChangedFile(path: String) -> ChangedFile {
    ChangedFile(
      oldPath: path, newPath: path, status: .modified,
      addedLines: 1, removedLines: 1, isBinary: false
    )
  }

  // MARK: - Happy path: worktreeSelected → changedFilesSucceeded

  @Test
  func worktreeSelectedKicksChangedFilesLoadAndStoresResult() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let worktree = Self.makeTempWorktree()
    let files: [ChangedFile] = [
      Self.sampleChangedFile(path: "a.swift"),
      Self.sampleChangedFile(path: "b.swift"),
      Self.sampleChangedFile(path: "c.swift"),
    ]

    let store = TestStore(initialState: DiffFeature.State()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.diffNumstat = { _ in files }
    }

    await store.send(
      .worktreeSelected(
        projectID: projectID, worktreeID: worktreeID, path: worktree.path
      )
    ) { state in
      state.projectID = projectID
      state.worktreeID = worktreeID
      state.worktreePath = worktree.path
      state.changedFiles = .loading
    }
    await store.receive(.changedFilesSucceeded(files)) { state in
      state.changedFiles = .loaded(files)
    }
  }

  // MARK: - Per-file load + cache

  @Test
  func fileRowTappedLoadsAndCachesDiff() async {
    let worktree = Self.makeTempWorktree(files: [
      "a.swift": "new contents\n"
    ])

    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: worktree.path,
        changedFiles: .loaded([Self.sampleChangedFile(path: "a.swift")])
      )
    ) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.showFileAtHEAD = { _, _ in "old contents\n" }
    }

    await store.send(.fileRowTapped(path: "a.swift")) { state in
      state.presentedFilePath = "a.swift"
      state.diffsByPath["a.swift"] = .loading
    }
    let expectedDocument = DiffDocument(
      files: [
        DiffFile(
          oldPath: "a.swift", newPath: "a.swift",
          oldContents: "old contents\n", newContents: "new contents\n"
        )
      ],
      title: "a.swift"
    )
    // `LoadedDiffDocument` uses identity equality so we can't predict the
    // reducer's wrapper instance in the state-mutation closure. Run the
    // store with non-exhaustive matching for the wrapper field, then
    // unwrap and compare contents on the live state below.
    store.exhaustivity = .off
    await store.receive(.diffSucceededFor(path: "a.swift", document: expectedDocument))
    if case .loaded(let wrapper) = store.state.diffsByPath["a.swift"] {
      #expect(wrapper.document == expectedDocument)
    } else {
      Issue.record("expected diffsByPath[a.swift] to be .loaded(...)")
    }

    // Re-tapping the open row is a no-op (chevron / × own the close path).
    await store.send(.fileRowTapped(path: "a.swift"))
  }

  // MARK: - Cancel on worktreeSelected

  @Test
  func worktreeSelectedDuringInflightLoadCancelsPriorEffect() async {
    let projectA = ProjectID()
    let worktreeA = WorktreeID()
    let pathA = Self.makeTempWorktree().path

    let projectB = ProjectID()
    let worktreeB = WorktreeID()
    let pathB = Self.makeTempWorktree().path

    let filesB: [ChangedFile] = [Self.sampleChangedFile(path: "z.swift")]

    let store = TestStore(initialState: DiffFeature.State()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      // First load hangs forever; second resolves immediately.
      $0.gitService.diffNumstat = { path in
        if path == pathA {
          // Hang until cancelled — cooperative cancellation drops us out.
          try? await Task.sleep(nanoseconds: 60_000_000_000)
          throw GitError.timedOut
        }
        return filesB
      }
    }

    await store.send(
      .worktreeSelected(projectID: projectA, worktreeID: worktreeA, path: pathA)
    ) { state in
      state.projectID = projectA
      state.worktreeID = worktreeA
      state.worktreePath = pathA
      state.changedFiles = .loading
    }

    // Switching Worktrees cancels the prior `diffNumstat` and starts a fresh one.
    await store.send(
      .worktreeSelected(projectID: projectB, worktreeID: worktreeB, path: pathB)
    ) { state in
      state.projectID = projectB
      state.worktreeID = worktreeB
      state.worktreePath = pathB
      state.changedFiles = .loading
    }
    await store.receive(.changedFilesSucceeded(filesB)) { state in
      state.changedFiles = .loaded(filesB)
    }
  }

  // MARK: - Drawer close

  @Test
  func drawerCloseRequestedClearsPresentationButKeepsCache() async {
    let cachedDoc = DiffDocument(
      files: [
        DiffFile(
          oldPath: "a.swift", newPath: "a.swift",
          oldContents: "old", newContents: "new"
        )
      ],
      title: "a.swift"
    )
    let cachedWrapper = DiffFeature.LoadedDiffDocument(cachedDoc)
    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: "/tmp",
        presentedFilePath: "a.swift",
        diffsByPath: ["a.swift": .loaded(cachedWrapper)]
      )
    ) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.drawerCloseRequested) { state in
      state.presentedFilePath = nil
    }
    #expect(store.state.diffsByPath["a.swift"] == .loaded(cachedWrapper))
  }

  // MARK: - Style change

  @Test
  func styleChangedUpdatesState() async {
    let store = TestStore(initialState: DiffFeature.State()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }
    await store.send(.styleChanged(.split)) { state in
      state.style = .split
    }
  }

  // MARK: - Stale per-file load cancellation on Worktree switch (C1)

  @Test
  func staleDiffLoadIsCancelledOnWorktreeSwitch() async {
    // The previous Worktree's per-file load must NOT write into the new
    // Worktree's `diffsByPath` if it completes after a Worktree switch.
    // We arrange a `showFileAtHEAD` stub that suspends until we explicitly
    // resume it, switch Worktrees while it's still pending, then resume —
    // and assert the reducer never receives `.diffSucceededFor` for the
    // original path against the post-switch state.
    let projectA = ProjectID()
    let worktreeA = WorktreeID()
    let pathA = Self.makeTempWorktree(files: ["a.swift": "a-new"]).path

    let projectB = ProjectID()
    let worktreeB = WorktreeID()
    let pathB = Self.makeTempWorktree().path

    actor Gate {
      private var continuation: CheckedContinuation<String, Never>?
      func wait() async -> String {
        await withCheckedContinuation { continuation = $0 }
      }
      func resume(with value: String) {
        continuation?.resume(returning: value)
        continuation = nil
      }
    }
    let gate = Gate()

    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: worktreeA,
        projectID: projectA,
        worktreePath: pathA,
        changedFiles: .loaded([Self.sampleChangedFile(path: "a.swift")])
      )
    ) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.diffNumstat = { _ in [] }
      $0.gitService.showFileAtHEAD = { _, _ in
        // Suspend here; the test resumes after switching Worktrees so
        // the reducer's per-path load is cancelled before this returns.
        await gate.wait()
      }
    }

    // Tap the row — kicks off the suspended `showFileAtHEAD` call.
    await store.send(.fileRowTapped(path: "a.swift")) { state in
      state.presentedFilePath = "a.swift"
      state.diffsByPath["a.swift"] = .loading
    }

    // Switch Worktrees while the per-file load is still pending. The
    // reducer's `worktreeSelected` branch must cancel the in-flight diff
    // load AND the suspended task is dropped without writing back.
    await store.send(
      .worktreeSelected(projectID: projectB, worktreeID: worktreeB, path: pathB)
    ) { state in
      state.projectID = projectB
      state.worktreeID = worktreeB
      state.worktreePath = pathB
      state.presentedFilePath = nil
      state.diffsByPath = [:]
      state.changedFiles = .loading
    }
    await store.receive(.changedFilesSucceeded([])) { state in
      state.changedFiles = .loaded([])
    }

    // Resume the suspended call. If cancellation didn't take, the reducer
    // would now receive `.diffSucceededFor(path: "a.swift", ...)` and
    // TestStore would flag an unexpected action at `finish()`.
    await gate.resume(with: "a-old")
    await store.finish()
    #expect(store.state.diffsByPath["a.swift"] == nil)
  }

  // MARK: - Refresh preserves cache (I5)

  @Test
  func refreshRequestedReloadsChangedFilesPreservingCache() async {
    let path = Self.makeTempWorktree(files: ["a.swift": "new"]).path
    let cachedDoc = DiffDocument(
      files: [
        DiffFile(oldPath: "a.swift", newPath: "a.swift", oldContents: "old", newContents: "new")
      ],
      title: "a.swift"
    )
    let cachedWrapper = DiffFeature.LoadedDiffDocument(cachedDoc)
    let initialFiles: [ChangedFile] = [Self.sampleChangedFile(path: "a.swift")]
    let refreshedFiles: [ChangedFile] = [
      Self.sampleChangedFile(path: "a.swift"),
      Self.sampleChangedFile(path: "b.swift"),
    ]

    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: path,
        changedFiles: .loaded(initialFiles),
        diffsByPath: ["a.swift": .loaded(cachedWrapper)]
      )
    ) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.diffNumstat = { _ in refreshedFiles }
    }

    await store.send(.refreshRequested) { state in
      state.changedFiles = .loading
    }
    await store.receive(.changedFilesSucceeded(refreshedFiles)) { state in
      state.changedFiles = .loaded(refreshedFiles)
    }
    // Per-file cache survives refresh.
    #expect(store.state.diffsByPath["a.swift"] == .loaded(cachedWrapper))
  }

  // MARK: - Changed-files load failure (I5)

  @Test
  func changedFilesFailureSurfacesAsErrorState() async {
    let path = Self.makeTempWorktree().path
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let store = TestStore(initialState: DiffFeature.State()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.diffNumstat = { _ in throw GitError.timedOut }
    }

    await store.send(
      .worktreeSelected(projectID: projectID, worktreeID: worktreeID, path: path)
    ) { state in
      state.projectID = projectID
      state.worktreeID = worktreeID
      state.worktreePath = path
      state.changedFiles = .loading
    }
    await store.receive(.changedFilesFailed(.timedOut)) { state in
      state.changedFiles = .error(.timedOut)
    }
  }

  // MARK: - Cached error short-circuits row tap (I5)

  @Test
  func fileRowTappedWithCachedErrorDoesNotRefetch() async {
    let cachedError = GitError.invalidInput("nope")
    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: "/tmp",
        diffsByPath: ["a.swift": .error(cachedError)]
      )
    ) {
      DiffFeature()
    } withDependencies: {
      // No stubs: the reducer must NOT call `showFileAtHEAD` on a cached
      // error, otherwise the unimplemented closure trips the test.
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.fileRowTapped(path: "a.swift")) { state in
      state.presentedFilePath = "a.swift"
    }
    // No effects expected; `await store.finish()` is implicit at scope end
    // and would flag a leak if the reducer kicked off a load.
    await store.finish()
    #expect(store.state.diffsByPath["a.swift"] == .error(cachedError))
  }

  // MARK: - Line-count cap (I5)

  @Test
  func lineCountCapTriggersTooLarge() async {
    // Build a working-tree file with > maxFileLines (5_000) lines but
    // well under the byte cap so the byte-count branch doesn't trip.
    let big = String(repeating: "x\n", count: DiffFeature.maxFileLines + 10)
    let worktree = Self.makeTempWorktree(files: ["x.swift": big])

    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: worktree.path,
        changedFiles: .loaded([Self.sampleChangedFile(path: "x.swift")])
      )
    ) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.showFileAtHEAD = { _, _ in "" }
    }

    let expectedCmd = "cd '\(worktree.path)' && git diff 'x.swift'"
    await store.send(.fileRowTapped(path: "x.swift")) { state in
      state.presentedFilePath = "x.swift"
      state.diffsByPath["x.swift"] = .loading
    }
    await store.receive(
      .diffTooLargeFor(
        path: "x.swift",
        reason: .lineCount(DiffFeature.maxFileLines + 11),
        copyCommand: expectedCmd
      )
    ) { state in
      state.diffsByPath["x.swift"] = .tooLarge(
        reason: .lineCount(DiffFeature.maxFileLines + 11), copyCommand: expectedCmd)
    }
  }

  // MARK: - LoadedDiffDocument equality is O(1) (I4)

  @Test
  func loadedStateEqualityIsConstantTime() {
    // Same instance ⇒ equal regardless of contents.
    let big = String(repeating: "x", count: 100_000)
    let doc = DiffDocument(
      files: [DiffFile(oldPath: "a", newPath: "a", oldContents: big, newContents: big + "y")],
      title: "a"
    )
    let wrapper = DiffFeature.LoadedDiffDocument(doc)
    #expect(wrapper == wrapper)

    // Different instances with equal content ⇒ NOT equal (identity-based).
    let wrapperA = DiffFeature.LoadedDiffDocument(doc)
    let wrapperB = DiffFeature.LoadedDiffDocument(doc)
    #expect(wrapperA != wrapperB)

    // State equality piggybacks on wrapper identity.
    let stateA = DiffFeature.State(diffsByPath: ["a": .loaded(wrapper)])
    let stateB = DiffFeature.State(diffsByPath: ["a": .loaded(wrapper)])
    #expect(stateA == stateB)
    let stateC = DiffFeature.State(diffsByPath: ["a": .loaded(wrapperA)])
    let stateD = DiffFeature.State(diffsByPath: ["a": .loaded(wrapperB)])
    #expect(stateC != stateD)
  }

  // MARK: - Too-large

  @Test
  func oversizedFileSurfacesAsTooLargeWithCopyCommand() async {
    // Build a 600 KB working-tree file to trip the byteCount cap.
    let big = String(repeating: "x", count: 600_000)
    let worktree = Self.makeTempWorktree(files: ["big.swift": big])

    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: worktree.path,
        changedFiles: .loaded([Self.sampleChangedFile(path: "big.swift")])
      )
    ) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.showFileAtHEAD = { _, _ in "" }
    }

    let expectedCmd = "cd '\(worktree.path)' && git diff 'big.swift'"
    await store.send(.fileRowTapped(path: "big.swift")) { state in
      state.presentedFilePath = "big.swift"
      state.diffsByPath["big.swift"] = .loading
    }
    await store.receive(
      .diffTooLargeFor(
        path: "big.swift",
        reason: .byteCount(600_000),
        copyCommand: expectedCmd
      )
    ) { state in
      state.diffsByPath["big.swift"] = .tooLarge(
        reason: .byteCount(600_000), copyCommand: expectedCmd)
    }
  }
}

/// Tests for the T11 Changes / History split on `DiffFeature` — covers tab
/// routing, first-page + paginate-more loading, idempotence guards, commit
/// selection / cache hit, and the worktree-switch / HEAD-change resets.
/// Separate top-level struct so the original `DiffFeatureTests` keeps its
/// pre-T11 shape and history-side fixtures don't leak into the Changes
/// fixtures.
@MainActor
struct DiffFeatureHistoryTests {
  // MARK: - Fixtures

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

  /// Build `count` commits with deterministic 40-char SHAs derived from the
  /// `prefix` + index. Length matches the live `git log` output so any
  /// future SHA-length validation in the reducer won't trip on test data.
  private static func sampleCommits(prefix: String, count: Int) -> [Commit] {
    (0..<count).map { idx in
      let suffix = String(repeating: "0", count: 40 - prefix.count - String(idx).count) + "\(idx)"
      return sampleCommit(id: prefix + suffix, subject: "subject-\(idx)")
    }
  }

  private static func makeState(
    worktreePath: String = "/tmp/wt"
  ) -> DiffFeature.State {
    var state = DiffFeature.State()
    state.projectID = ProjectID()
    state.worktreeID = WorktreeID()
    state.worktreePath = worktreePath
    return state
  }

  // MARK: - 1. Tab routing

  @Test
  func tabSelectedChangesActiveTab() async {
    let store = TestStore(initialState: Self.makeState()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }
    #expect(store.state.selectedTab == .changes)
    await store.send(.tabSelected(.history)) { state in
      state.selectedTab = .history
    }
  }

  // MARK: - 2. First-page load on appear

  @Test
  func historyAppearedTriggersFirstPageLoad() async {
    let commits = Self.sampleCommits(prefix: "a", count: 3)
    let store = TestStore(initialState: Self.makeState()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.log = { _, cursor in
        // Verify the reducer hands us the expected first-page cursor.
        #expect(cursor.offset == 0)
        #expect(cursor.limit == 50)
        return LogPage(cursor: cursor, commits: commits, hasMore: true)
      }
    }

    await store.send(.historyAppeared) { state in
      state.historyState.loading = true
    }
    await store.receive(.historyPageSucceeded(commits, hasMore: true)) { state in
      state.historyState.commits = commits
      state.historyState.nextOffset = commits.count
      state.historyState.hasMore = true
      state.historyState.loading = false
    }
  }

  // MARK: - 3. Idempotent: already loaded

  @Test
  func historyAppearedIsIdempotentWhenLoaded() async {
    let commits = Self.sampleCommits(prefix: "b", count: 2)
    var seed = Self.makeState()
    seed.historyState.commits = commits
    seed.historyState.nextOffset = commits.count
    seed.historyState.hasMore = true

    let store = TestStore(initialState: seed) {
      DiffFeature()
    } withDependencies: {
      // No `log` stub: a re-fire on a loaded cache would trip
      // `unimplemented` and surface as a test failure.
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.historyAppeared)
    await store.finish()
  }

  // MARK: - 4. Idempotent: load already in flight

  @Test
  func historyAppearedIsIdempotentWhileLoading() async {
    var seed = Self.makeState()
    seed.historyState.loading = true

    let store = TestStore(initialState: seed) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.historyAppeared)
    await store.finish()
  }

  // MARK: - 5. Load-more appends + advances offset

  @Test
  func historyLoadNextPageRequestedAppendsAndAdvances() async {
    let firstPage = Self.sampleCommits(prefix: "c", count: 50)
    let secondPage = Self.sampleCommits(prefix: "d", count: 20)
    var seed = Self.makeState()
    seed.historyState.commits = firstPage
    seed.historyState.nextOffset = 50
    seed.historyState.hasMore = true

    let store = TestStore(initialState: seed) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.log = { _, cursor in
        #expect(cursor.offset == 50)
        #expect(cursor.limit == 50)
        return LogPage(cursor: cursor, commits: secondPage, hasMore: false)
      }
    }

    await store.send(.historyLoadNextPageRequested) { state in
      state.historyState.loading = true
    }
    await store.receive(.historyPageSucceeded(secondPage, hasMore: false)) { state in
      state.historyState.commits = firstPage + secondPage
      state.historyState.nextOffset = 70
      state.historyState.hasMore = false
      state.historyState.loading = false
    }
  }

  // MARK: - 6. Load-more gated on hasMore

  @Test
  func historyLoadNextPageRequestedGatedOnHasMore() async {
    var seed = Self.makeState()
    seed.historyState.commits = Self.sampleCommits(prefix: "e", count: 10)
    seed.historyState.nextOffset = 10
    seed.historyState.hasMore = false

    let store = TestStore(initialState: seed) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.historyLoadNextPageRequested)
    await store.finish()
  }

  // MARK: - 7. Commit tap sets selection + loads diff

  @Test
  func historyCommitTappedSetsSelectionAndLoads() async {
    let sha = "abc0000000000000000000000000000000000000"
    let unified = UnifiedDiff(scope: .commit(sha: sha), files: [])

    let store = TestStore(initialState: Self.makeState()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.commitDiff = { _, requestedSha, _ in
        #expect(requestedSha == sha)
        return unified
      }
    }

    await store.send(.historyCommitTapped(sha: sha, subject: "x")) { state in
      state.presentedCommitSha = sha
      state.diffsByCommit[sha] = .loading
    }
    // `LoadedDiffDocument` is identity-equatable; we can't predict the
    // wrapper instance the reducer builds, so use non-exhaustive matching
    // for the wrapper field and verify the document contents below.
    store.exhaustivity = .off
    let expectedDocument = DiffDocument(
      files: [],
      title: String(sha.prefix(7)),
      fallbackPatch: ""
    )
    await store.receive(.commitDiffSucceededFor(sha: sha, document: expectedDocument))
    if case .loaded(let wrapper) = store.state.diffsByCommit[sha] {
      #expect(wrapper.document == expectedDocument)
    } else {
      Issue.record("expected diffsByCommit[\(sha)] to be .loaded(...)")
    }
  }

  // MARK: - 8. Cache hit on re-tap

  @Test
  func historyCommitTappedReusesCacheOnRepeat() async {
    let shaA = "aaaa000000000000000000000000000000000000"
    let shaB = "bbbb000000000000000000000000000000000000"

    actor CallCounter {
      private(set) var calls: [String] = []
      func record(_ sha: String) { calls.append(sha) }
      func count() -> Int { calls.count }
    }
    let counter = CallCounter()

    let store = TestStore(initialState: Self.makeState()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.commitDiff = { _, sha, _ in
        await counter.record(sha)
        return UnifiedDiff(scope: .commit(sha: sha), files: [])
      }
    }
    store.exhaustivity = .off

    // 1) Tap A → fetch.
    await store.send(.historyCommitTapped(sha: shaA, subject: "a"))
    await store.receive(\.commitDiffSucceededFor)
    // 2) Tap B → fetch.
    await store.send(.historyCommitTapped(sha: shaB, subject: "b"))
    await store.receive(\.commitDiffSucceededFor)
    // 3) Re-tap A → cache hit, no new fetch.
    await store.send(.historyCommitTapped(sha: shaA, subject: "a"))
    await store.finish()

    let totalCalls = await counter.count()
    #expect(totalCalls == 2)
    #expect(store.state.presentedCommitSha == shaA)
  }

  // MARK: - 9. Worktree switch resets history side

  @Test
  func worktreeSelectedResetsHistorySide() async {
    let commits = Self.sampleCommits(prefix: "f", count: 3)
    let cachedDoc = DiffDocument(files: [], title: "abcdef0", fallbackPatch: "")
    var seed = Self.makeState(worktreePath: "/tmp/old")
    seed.historyState.commits = commits
    seed.historyState.nextOffset = commits.count
    seed.historyState.hasMore = false
    seed.presentedCommitSha = "abcdef00000000000000000000000000000000000"
    seed.diffsByCommit["abcdef00000000000000000000000000000000000"] = .loaded(
      DiffFeature.LoadedDiffDocument(cachedDoc))
    seed.selectedTab = .history  // user preference must persist

    let newProject = ProjectID()
    let newWorktree = WorktreeID()
    let newPath = "/tmp/new"

    let store = TestStore(initialState: seed) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.diffNumstat = { _ in [] }
    }
    store.exhaustivity = .off

    await store.send(
      .worktreeSelected(projectID: newProject, worktreeID: newWorktree, path: newPath)
    ) { state in
      state.projectID = newProject
      state.worktreeID = newWorktree
      state.worktreePath = newPath
      state.presentedFilePath = nil
      state.diffsByPath = [:]
      state.historyState = .init()
      state.presentedCommitSha = nil
      state.diffsByCommit = [:]
      state.changedFiles = .loading
      // selectedTab stays .history — user preference persists across switches.
    }
    await store.finish()
    #expect(store.state.selectedTab == .history)
  }

  // MARK: - 10. HEAD change resets history side

  @Test
  func headChangedForCurrentWorktreeResetsHistorySide() async {
    let commits = Self.sampleCommits(prefix: "g", count: 5)
    let cachedDoc = DiffDocument(files: [], title: "1234567", fallbackPatch: "")
    var seed = Self.makeState()
    seed.historyState.commits = commits
    seed.historyState.nextOffset = commits.count
    seed.historyState.hasMore = false
    seed.presentedCommitSha = "12345670000000000000000000000000000000000"
    seed.diffsByCommit["12345670000000000000000000000000000000000"] = .loaded(
      DiffFeature.LoadedDiffDocument(cachedDoc))
    seed.selectedTab = .history

    let store = TestStore(initialState: seed) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.headChangedForCurrentWorktree) { state in
      state.historyState = .init()
      state.presentedCommitSha = nil
      state.diffsByCommit = [:]
      // selectedTab stays .history.
    }
    #expect(store.state.selectedTab == .history)
  }

  // MARK: - 11. Load failure surfaces as error

  @Test
  func historyPageFailedCapturesError() async {
    let store = TestStore(initialState: Self.makeState()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.log = { _, _ in throw GitError.timedOut }
    }

    await store.send(.historyAppeared) { state in
      state.historyState.loading = true
    }
    await store.receive(.historyPageFailed(.timedOut)) { state in
      state.historyState.loading = false
      state.historyState.error = .timedOut
    }
  }
}
