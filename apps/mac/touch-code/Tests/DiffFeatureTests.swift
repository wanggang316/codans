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

  // MARK: - Drawer close clears both selections (T14)

  @Test
  func drawerCloseRequestedClearsBothPresentations() async {
    let store = TestStore(initialState: {
      var s = DiffFeature.State()
      s.presentedFilePath = "src/App.swift"
      s.presentedCommitSha = "abc1234567890000000000000000000000000000"
      return s
    }()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.drawerCloseRequested) {
      $0.presentedFilePath = nil
      $0.presentedCommitSha = nil
    }
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

  // MARK: - Retry re-issues load on .error cache state (FU-T14)

  @Test
  func fileRowTappedRetriesAfterError() async {
    // Pre-populate `.error` cache and `presentedFilePath` to mirror the
    // state a Retry-button tap arrives in: the user already selected the
    // row, the prior load failed, and now they're hitting Retry. The
    // reducer must reset the cache slot to `.loading` and issue a fresh
    // `showFileAtHEAD` call rather than short-circuiting.
    let worktree = Self.makeTempWorktree(files: ["x.swift": "new\n"])
    let cachedError = GitError.exec(code: 1, stderr: "fatal: …")
    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: worktree.path,
        presentedFilePath: "x.swift",
        diffsByPath: ["x.swift": .error(cachedError)]
      )
    ) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.showFileAtHEAD = { _, _ in "OK" }
    }

    await store.send(.fileRowTapped(path: "x.swift")) { state in
      state.diffsByPath["x.swift"] = .loading
    }
    let expectedDocument = DiffDocument(
      files: [
        DiffFile(oldPath: "x.swift", newPath: "x.swift", oldContents: "OK", newContents: "new\n")
      ],
      title: "x.swift"
    )
    // `LoadedDiffDocument` is identity-equatable; match the action then
    // unwrap the wrapper to compare contents (same pattern as
    // `fileRowTappedLoadsAndCachesDiff`).
    store.exhaustivity = .off
    await store.receive(.diffSucceededFor(path: "x.swift", document: expectedDocument))
    if case .loaded(let wrapper) = store.state.diffsByPath["x.swift"] {
      #expect(wrapper.document == expectedDocument)
    } else {
      Issue.record("expected diffsByPath[x.swift] to be .loaded(...) after retry")
    }
  }

  // MARK: - Cache hit on .loaded short-circuits row tap (FU-T14 sanity)

  @Test
  func fileRowTappedNoOpsWhenAlreadyLoaded() async {
    // The fix introduced an explicit `.loaded` short-circuit; this guards
    // against a regression where Retry's plumbing accidentally re-loads
    // already-loaded rows.
    let cachedDoc = DiffDocument(
      files: [
        DiffFile(oldPath: "x", newPath: "x", oldContents: "old", newContents: "new")
      ],
      title: "x"
    )
    let cachedWrapper = DiffFeature.LoadedDiffDocument(cachedDoc)
    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: "/tmp",
        diffsByPath: ["x": .loaded(cachedWrapper)]
      )
    ) {
      DiffFeature()
    } withDependencies: {
      // No `showFileAtHEAD` stub: an unintended refetch would trip the
      // `unimplemented` closure and fail the test.
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.fileRowTapped(path: "x")) { state in
      state.presentedFilePath = "x"
    }
    await store.finish()
    if case .loaded(let wrapper) = store.state.diffsByPath["x"] {
      #expect(wrapper === cachedWrapper)
    } else {
      Issue.record("expected diffsByPath[x] to remain .loaded(cachedWrapper)")
    }
  }

  // MARK: - History-side Retry re-issues commit-diff load on .error (FU-T14)

  @Test
  func historyCommitTappedRetriesAfterError() async {
    // History-side symmetric variant of `fileRowTappedRetriesAfterError`.
    // Pre-populate `.error` for the selected commit and assert the reducer
    // drops back to `.loading` and re-fires `commitDiff` rather than
    // short-circuiting on the cached error.
    let sha = "abc1234000000000000000000000000000000000"
    let cachedError = GitError.exec(code: 1, stderr: "fatal: …")
    let unified = UnifiedDiff(scope: .commit(sha: sha), files: [])
    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: "/tmp/wt",
        presentedCommitSha: sha,
        diffsByCommit: [sha: .error(cachedError)]
      )
    ) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.commitDiff = { _, requestedSha, _ in
        #expect(requestedSha == sha)
        return unified
      }
    }

    await store.send(.historyCommitTapped(sha: sha)) { state in
      state.diffsByCommit[sha] = .loading
    }
    store.exhaustivity = .off
    let expectedDocument = DiffDocument(
      files: [],
      title: String(sha.prefix(7)),
      fallbackPatch: ""
    )
    await store.receive(
      .commitDiffSucceededFor(sha: sha, document: expectedDocument, filePaths: [], changeTypes: [:])
    )
    if case .loaded(let wrapper) = store.state.diffsByCommit[sha] {
      #expect(wrapper.document == expectedDocument)
    } else {
      Issue.record("expected diffsByCommit[\(sha)] to be .loaded(...) after retry")
    }
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

    await store.send(.historyCommitTapped(sha: sha)) { state in
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
    await store.receive(
      .commitDiffSucceededFor(sha: sha, document: expectedDocument, filePaths: [], changeTypes: [:])
    )
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
    await store.send(.historyCommitTapped(sha: shaA))
    await store.receive(\.commitDiffSucceededFor)
    // 2) Tap B → fetch.
    await store.send(.historyCommitTapped(sha: shaB))
    await store.receive(\.commitDiffSucceededFor)
    // 3) Re-tap A → cache hit, no new fetch.
    await store.send(.historyCommitTapped(sha: shaA))
    await store.finish()

    let totalCalls = await counter.count()
    #expect(totalCalls == 2)
    #expect(store.state.presentedCommitSha == shaA)
  }

  // MARK: - 8b. Re-tapping the presented sha toggles the selection off

  @Test
  func historyCommitTappedTogglesPresentedSha() async {
    // Tapping the currently-presented sha clears the selection (drawer
    // closes). The per-commit cache stays — a future third tap re-presents
    // from cache without a re-fetch.
    let sha = "abc0000000000000000000000000000000000000"
    let cachedDoc = DiffDocument(files: [], title: "abc0000", fallbackPatch: "")
    let cachedWrapper = DiffFeature.LoadedDiffDocument(cachedDoc)
    let store = TestStore(
      initialState: DiffFeature.State(
        worktreeID: WorktreeID(),
        projectID: ProjectID(),
        worktreePath: "/tmp/wt",
        presentedCommitSha: sha,
        diffsByCommit: [sha: .loaded(cachedWrapper)]
      )
    ) {
      DiffFeature()
    } withDependencies: {
      // No `commitDiff` stub — an unintended refetch would trip
      // `unimplemented` and fail the test.
      $0.gitService = GitServiceClient.testValue
    }

    await store.send(.historyCommitTapped(sha: sha)) { state in
      state.presentedCommitSha = nil
      // Cache stays — see decision log on the toggle behavior.
    }
    // Cache survives the toggle so the next tap can short-circuit.
    #expect(store.state.diffsByCommit[sha] == .loaded(cachedWrapper))
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
    seed.presentedCommitSha = "abcdef0000000000000000000000000000000000"
    seed.diffsByCommit["abcdef0000000000000000000000000000000000"] = .loaded(
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
    seed.presentedCommitSha = "1234567000000000000000000000000000000000"
    seed.diffsByCommit["1234567000000000000000000000000000000000"] = .loaded(
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

  // MARK: - 10c. commitMessage lazy fetch + idempotence

  @Test
  func commitMessageRequestedFetchesAndCaches() async {
    let sha = "abc1234567890000000000000000000000000000"
    let full = "subject line\n\nbody paragraph"
    let store = TestStore(initialState: Self.makeState()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.commitMessage = { requestedSha, _ in
        #expect(requestedSha == sha)
        return full
      }
    }
    await store.send(.commitMessageRequested(sha: sha))
    await store.receive(.commitMessageLoaded(sha: sha, message: full)) { state in
      state.commitMessageByID[sha] = full
    }
  }

  @Test
  func commitMessageRequestedIsIdempotentOnCachedSha() async {
    let sha = "abc1234567890000000000000000000000000000"
    var seed = Self.makeState()
    seed.commitMessageByID[sha] = "already cached"
    let store = TestStore(initialState: seed) {
      DiffFeature()
    } withDependencies: {
      // No `commitMessage` stub — an unintended refetch would trip
      // `unimplemented` and fail the test.
      $0.gitService = GitServiceClient.testValue
    }
    await store.send(.commitMessageRequested(sha: sha))
    await store.finish()
  }

  @Test
  func commitMessageFailedCachesEmptySentinel() async {
    let sha = "abc1234567890000000000000000000000000000"
    let store = TestStore(initialState: Self.makeState()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.commitMessage = { _, _ in throw GitError.timedOut }
    }
    await store.send(.commitMessageRequested(sha: sha))
    await store.receive(.commitMessageFailed(sha: sha, error: .timedOut)) { state in
      // Empty string sentinel — the view falls back to `commit.subject`
      // and the reducer's idempotence guard short-circuits a retry on
      // the next hover.
      state.commitMessageByID[sha] = ""
    }
  }

  // MARK: - 10b. commitDiffSucceededFor stores filePaths alongside the document

  @Test
  func commitDiffSucceededForStoresFilePaths() async {
    // The action carries the file-path list the drawer file picker renders
    // in History mode. Verify the reducer routes it into
    // `commitFilePathsByID` keyed by the same sha as `diffsByCommit`.
    let sha = "abc1234567890000000000000000000000000000"
    let doc = DiffDocument(files: [], title: "abc1234", fallbackPatch: "diff ...")
    let store = TestStore(initialState: Self.makeState()) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
    }
    // `LoadedDiffDocument` is identity-equatable; use non-exhaustive for
    // the diffsByCommit field and verify it on the live state below.
    store.exhaustivity = .off
    await store.send(
      .commitDiffSucceededFor(sha: sha, document: doc, filePaths: ["a.swift", "b/c.txt"], changeTypes: [:])
    )
    #expect(store.state.commitFilePathsByID[sha] == ["a.swift", "b/c.txt"])
    if case .loaded(let wrapper) = store.state.diffsByCommit[sha] {
      #expect(wrapper.document == doc)
    } else {
      Issue.record("expected diffsByCommit[\(sha)] to be .loaded(...) after success action")
    }
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

  // MARK: - 12. Refresh request resets + kicks first page (FU-T12)

  @Test
  func historyRefreshRequestedResetsAndKicksFirstPage() async {
    let staleSha = String(repeating: "b", count: 40)
    let staleCommit = Self.sampleCommit(id: staleSha, subject: "stale")
    let freshCommits = Self.sampleCommits(prefix: "f", count: 1)
    let cachedDoc = DiffDocument(files: [], title: "bbbbbbb", fallbackPatch: "")

    var seed = Self.makeState()
    seed.selectedTab = .history
    seed.historyState.commits = [staleCommit]
    seed.historyState.nextOffset = 1
    seed.historyState.hasMore = false
    seed.presentedCommitSha = staleSha
    seed.diffsByCommit[staleSha] = .loaded(DiffFeature.LoadedDiffDocument(cachedDoc))

    let store = TestStore(initialState: seed) {
      DiffFeature()
    } withDependencies: {
      $0.gitService = GitServiceClient.testValue
      $0.gitService.log = { _, cursor in
        // Refresh re-fires `.historyAppeared`, which loads from offset 0.
        #expect(cursor.offset == 0)
        #expect(cursor.limit == 50)
        return LogPage(cursor: cursor, commits: freshCommits, hasMore: false)
      }
    }

    // Step 1: the refresh arm wipes history state, selection, and per-commit
    // cache before re-firing `.historyAppeared`.
    await store.send(.historyRefreshRequested) { state in
      state.historyState = .init()
      state.presentedCommitSha = nil
      state.diffsByCommit = [:]
    }
    // Step 2: the `.send(.historyAppeared)` inside the refresh effect
    // promotes `loading = true` before the log call resolves.
    await store.receive(\.historyAppeared) { state in
      state.historyState.loading = true
    }
    // Step 3: the log call returns the fresh page.
    await store.receive(.historyPageSucceeded(freshCommits, hasMore: false)) { state in
      state.historyState.commits = freshCommits
      state.historyState.nextOffset = freshCommits.count
      state.historyState.hasMore = false
      state.historyState.loading = false
    }
  }
}

/// Direct unit tests for `DiffFeature.renderUnifiedDiffAsPatch`. The serializer
/// re-emits parsed `UnifiedDiff` shapes as canonical `git diff` text, which is
/// what `DiffDocument(fallbackPatch:)` feeds straight to the WebView. Pins the
/// expected text-format scaffolding so a regression in the serializer would
/// fail loudly rather than corrupt every commit-diff render path. (FU-T11.)
struct DiffFeaturePatchSerializerTests {
  @Test
  func renderUnifiedDiffAsPatchEmitsAddedFileWithDevNullSource() {
    let file = FileChange(
      id: "new.txt", kind: .added, isBinary: false,
      linesAdded: 1, linesRemoved: 0,
      hunks: [
        DiffHunk(
          header: "@@ -0,0 +1 @@", oldStart: 0, oldCount: 0,
          newStart: 1, newCount: 1,
          lines: [DiffLine(kind: .added, text: "hello")]
        )
      ]
    )
    let out = DiffFeature.renderUnifiedDiffAsPatch(
      UnifiedDiff(scope: .commit(sha: "abc1234"), files: [file])
    )
    #expect(out.contains("diff --git a/new.txt b/new.txt"))
    #expect(out.contains("new file mode 100644"))
    #expect(out.contains("--- /dev/null"))
    #expect(out.contains("+++ b/new.txt"))
    #expect(out.contains("+hello"))
  }

  @Test
  func renderUnifiedDiffAsPatchEmitsDeletedFileWithDevNullTarget() {
    let file = FileChange(
      id: "old.txt", kind: .deleted, isBinary: false,
      linesAdded: 0, linesRemoved: 1,
      hunks: [
        DiffHunk(
          header: "@@ -1 +0,0 @@", oldStart: 1, oldCount: 1,
          newStart: 0, newCount: 0,
          lines: [DiffLine(kind: .removed, text: "goodbye")]
        )
      ]
    )
    let out = DiffFeature.renderUnifiedDiffAsPatch(
      UnifiedDiff(scope: .commit(sha: "def5678"), files: [file])
    )
    #expect(out.contains("diff --git a/old.txt b/old.txt"))
    #expect(out.contains("deleted file mode 100644"))
    #expect(out.contains("--- a/old.txt"))
    #expect(out.contains("+++ /dev/null"))
    #expect(out.contains("-goodbye"))
  }

  @Test
  func renderUnifiedDiffAsPatchEmitsRenamedFileWithDistinctPaths() {
    let file = FileChange(
      id: "new/path.txt",
      kind: .renamed(from: "old/path.txt"),
      isBinary: false,
      linesAdded: 0, linesRemoved: 0,
      hunks: []
    )
    let out = DiffFeature.renderUnifiedDiffAsPatch(
      UnifiedDiff(scope: .commit(sha: "ren1234"), files: [file])
    )
    #expect(out.contains("diff --git a/old/path.txt b/new/path.txt"))
    #expect(out.contains("rename from old/path.txt"))
    #expect(out.contains("rename to new/path.txt"))
  }

  @Test
  func renderUnifiedDiffAsPatchEmitsBinaryFileShortcut() {
    let file = FileChange(
      id: "image.png", kind: .modified, isBinary: true,
      linesAdded: 0, linesRemoved: 0,
      hunks: []
    )
    let out = DiffFeature.renderUnifiedDiffAsPatch(
      UnifiedDiff(scope: .commit(sha: "bin1234"), files: [file])
    )
    #expect(out.contains("diff --git a/image.png b/image.png"))
    #expect(out.contains("Binary files a/image.png and b/image.png differ"))
  }

  @Test
  func renderUnifiedDiffAsPatchEmitsModifiedFileWithMultiLineHunk() {
    let file = FileChange(
      id: "src/x.swift", kind: .modified, isBinary: false,
      linesAdded: 1, linesRemoved: 1,
      hunks: [
        DiffHunk(
          header: "@@ -1,3 +1,3 @@", oldStart: 1, oldCount: 3,
          newStart: 1, newCount: 3,
          lines: [
            DiffLine(kind: .context, text: "context-before"),
            DiffLine(kind: .removed, text: "old-line"),
            DiffLine(kind: .added, text: "new-line"),
            DiffLine(kind: .context, text: "context-after"),
          ]
        )
      ]
    )
    let out = DiffFeature.renderUnifiedDiffAsPatch(
      UnifiedDiff(scope: .commit(sha: "mod1234"), files: [file])
    )
    #expect(out.contains("diff --git a/src/x.swift b/src/x.swift"))
    #expect(out.contains("--- a/src/x.swift"))
    #expect(out.contains("+++ b/src/x.swift"))
    #expect(out.contains("@@ -1,3 +1,3 @@"))
    #expect(out.contains(" context-before"))  // space prefix for context
    #expect(out.contains("-old-line"))  // - prefix for removed
    #expect(out.contains("+new-line"))  // + prefix for added
    #expect(out.contains(" context-after"))
  }
}
