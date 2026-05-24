import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// TestStore coverage for GitHubFeature. Exercises every action path with stubbed
/// GitHubClient closures. No network, no gh subprocess.
@MainActor
struct GitHubFeatureTests {
  // MARK: - availability

  @Test
  func onAppearProbesAvailabilityAndStoresResult() async {
    let store = Self.makeStore { client in
      client.availability = { .available(host: "github.com", user: "gump") }
    }
    await store.send(.onAppear)
    await store.receive {
      if case .availabilityProbed(.available, _) = $0 { return true }
      return false
    } assert: {
      $0.availability = .available(host: "github.com", user: "gump")
      $0.availabilityProbedAt = Self.fixedDate
    }
  }

  @Test
  func onAppearWithinFreshnessWindowSkipsProbe() async {
    var seed = GitHubFeature.State()
    seed.availability = .available(host: "github.com", user: "gump")
    seed.availabilityProbedAt = Self.fixedDate
    let store = Self.makeStore(initialState: seed) { client in
      client.availability = {
        Issue.record("availability should not be called inside the 30 s window")
        return .unknown
      }
    }
    await store.send(.onAppear)
  }

  @Test
  func refreshAvailabilityAlwaysReprobes() async {
    var seed = GitHubFeature.State()
    seed.availability = .available(host: "github.com", user: "gump")
    seed.availabilityProbedAt = Self.fixedDate
    let store = Self.makeStore(initialState: seed) { client in
      client.availability = { .unavailable(reason: "gh missing") }
    }
    await store.send(.refreshAvailabilityRequested) {
      $0.availabilityProbedAt = nil
    }
    await store.receive {
      if case .availabilityProbed(.unavailable, _) = $0 { return true }
      return false
    } assert: {
      $0.availability = .unavailable(reason: "gh missing")
      $0.availabilityProbedAt = Self.fixedDate
    }
  }

  // MARK: - snapshot loading

  @Test
  func worktreeBecameVisibleLoadsSnapshot() async {
    let expected = Self.stubSnapshot(number: 42)
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.pullRequest = { _, _ in expected }
    }
    await store.send(.worktreeBecameVisible(wid, branch: "feature", worktreePath: Self.path)) {
      $0.worktreePaths[wid] = Self.path
      $0.loading.insert(wid)
    }
    await store.receive(.snapshotLoaded(wid, .success(expected))) {
      $0.loading.remove(wid)
      $0.snapshots[wid] = expected
      $0.snapshotLoadedAt[wid] = Self.fixedDate
      $0.lastError[wid] = nil
    }
    // 0013 M5 retired the per-Worktree checks prefetch. `snapshot.checkRollup` is now
    // populated by the v2 batched path; the single-branch refresh still uses the v1
    // `gh pr view` parser which leaves checkRollup empty (acceptable — next Project
    // activation refills it).
  }

  @Test
  func worktreeBecameVisibleSkipsWhenCached() async {
    let snap = Self.stubSnapshot(number: 1)
    let wid = WorktreeID()
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = snap
    seed.snapshotLoadedAt[wid] = Self.fixedDate
    let store = Self.makeStore(initialState: seed) { client in
      client.pullRequest = { _, _ in
        Issue.record("pullRequest must not be called when cache is fresh")
        return nil
      }
    }
    await store.send(.worktreeBecameVisible(wid, branch: "b", worktreePath: Self.path)) {
      $0.worktreePaths[wid] = Self.path
    }
  }

  @Test
  func worktreeBecameVisibleWhenLoadingIsNoop() async {
    let wid = WorktreeID()
    var seed = GitHubFeature.State()
    seed.loading.insert(wid)
    let store = Self.makeStore(initialState: seed) { client in
      client.pullRequest = { _, _ in
        Issue.record("pullRequest must not be called when a fetch is already in flight")
        return nil
      }
    }
    await store.send(.worktreeBecameVisible(wid, branch: "b", worktreePath: Self.path)) {
      $0.worktreePaths[wid] = Self.path
    }
  }

  @Test
  func refreshRequestedForcesReload() async {
    let existing = Self.stubSnapshot(number: 1)
    let refreshed = Self.stubSnapshot(number: 1, title: "updated")
    let wid = WorktreeID()
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = existing
    seed.snapshotLoadedAt[wid] = Self.fixedDate
    let store = Self.makeStore(initialState: seed) { client in
      client.pullRequest = { _, _ in refreshed }
    }
    await store.send(.refreshRequested(wid, branch: "b", worktreePath: Self.path)) {
      $0.worktreePaths[wid] = Self.path
      $0.snapshotLoadedAt[wid] = nil
      $0.loading.insert(wid)
    }
    await store.receive(.snapshotLoaded(wid, .success(refreshed))) {
      $0.loading.remove(wid)
      $0.snapshots[wid] = refreshed
      $0.snapshotLoadedAt[wid] = Self.fixedDate
    }
  }

  @Test
  func snapshotFailurePopulatesLastError() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.pullRequest = { _, _ in throw GitHubError.notAuthenticated(host: "github.com") }
    }
    await store.send(.worktreeBecameVisible(wid, branch: "b", worktreePath: Self.path)) {
      $0.worktreePaths[wid] = Self.path
      $0.loading.insert(wid)
    }
    await store.receive {
      if case .snapshotLoaded(let w, .failure) = $0, w == wid { return true }
      return false
    } assert: {
      $0.loading.remove(wid)
      $0.snapshotLoadedAt[wid] = Self.fixedDate
      $0.lastError[wid] = .notAuthenticated(host: "github.com")
    }
  }

  @Test
  func snapshotLoadedWithNilPRClearsCachedSnapshot() async {
    let existing = Self.stubSnapshot(number: 1)
    let wid = WorktreeID()
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = existing
    seed.loading.insert(wid)
    let store = Self.makeStore(initialState: seed)
    await store.send(.snapshotLoaded(wid, .success(nil))) {
      $0.snapshots[wid] = nil
      $0.snapshotLoadedAt[wid] = Self.fixedDate
      $0.loading = []
      $0.lastError[wid] = nil
    }
  }

  // MARK: - popover

  @Test
  func presentPopoverWithCachedSnapshotFetchesWorkflowRun() async {
    // 0013 M6 retired the per-popover `gh pr checks` fetch; check data now travels
    // with the snapshot. The popover still fetches the latest workflow run to seed
    // the "Rerun failed jobs" button — that's all `presentPopover` triggers now.
    let wid = WorktreeID()
    let snap = Self.stubSnapshot(number: 42, headRefName: "feature/github01")
    let run = Self.stubRun(runID: 99)
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = snap
    let store = Self.makeStore(initialState: seed) { client in
      client.latestWorkflowRun = { branch, _ in
        #expect(branch == "feature/github01")
        return run
      }
    }
    await store.send(.presentPopover(wid, worktreePath: Self.path)) {
      $0.popoverTarget = wid
      $0.worktreePaths[wid] = Self.path
    }
    await store.receive(.workflowRunLoaded(prNumber: 42, .success(run))) {
      $0.latestWorkflowRuns[42] = run
    }
  }

  @Test
  func dismissPopoverClearsTarget() async {
    let wid = WorktreeID()
    var seed = GitHubFeature.State()
    seed.popoverTarget = wid
    let store = Self.makeStore(initialState: seed)
    await store.send(.dismissPopover) {
      $0.popoverTarget = nil
    }
  }

  // MARK: - merge

  @Test
  func mergeSucceededEmitsDelegate() async {
    let wid = WorktreeID()
    let snap = Self.stubSnapshot(number: 99, state: .open, headRefName: "feature/test")
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = snap
    let store = Self.makeStore(initialState: seed) { client in
      client.merge = { prNumber, strategy, _ in
        #expect(prNumber == 99)
        #expect(strategy == .squash)
      }
      client.pullRequest = { _, _ in snap }  // post-mutation refresh call
    }
    await store.send(.mergeRequested(wid, prNumber: 99, strategy: .squash, worktreePath: Self.path)) {
      $0.mutating.insert(wid)
      $0.worktreePaths[wid] = Self.path
    }
    await store.receive(.mergeCompleted(wid, prNumber: 99, .success(.init()))) {
      $0.mutating.remove(wid)
      $0.snapshotLoadedAt[wid] = nil
      $0.loading.insert(wid)
    }
    await store.receive(.delegate(.pullRequestMerged(wid, snapshot: snap)))
    await store.receive(.snapshotLoaded(wid, .success(snap))) {
      $0.loading.remove(wid)
      $0.snapshots[wid] = snap
      $0.snapshotLoadedAt[wid] = Self.fixedDate
      $0.lastError[wid] = nil
    }
  }

  @Test
  func mergeFailureSurfacesMergeConflict() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.merge = { _, _, _ in throw GitHubError.mergeConflict }
    }
    await store.send(.mergeRequested(wid, prNumber: 1, strategy: .squash, worktreePath: Self.path)) {
      $0.mutating.insert(wid)
      $0.worktreePaths[wid] = Self.path
    }
    await store.receive {
      if case .mergeCompleted(let w, 1, .failure) = $0, w == wid { return true }
      return false
    } assert: {
      $0.mutating.remove(wid)
      $0.lastError[wid] = .mergeConflict
    }
  }

  @Test
  func mergeWhileMutatingIsNoop() async {
    let wid = WorktreeID()
    var seed = GitHubFeature.State()
    seed.mutating.insert(wid)
    let store = Self.makeStore(initialState: seed) { client in
      client.merge = { _, _, _ in
        Issue.record("merge must not be called when another mutation is in flight")
      }
    }
    await store.send(.mergeRequested(wid, prNumber: 1, strategy: .squash, worktreePath: Self.path))
  }

  @Test
  func closeDispatchesGhClient() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.close = { prNumber, _ in #expect(prNumber == 7) }
    }
    await store.send(.closeRequested(wid, prNumber: 7, worktreePath: Self.path)) {
      $0.mutating.insert(wid)
      $0.worktreePaths[wid] = Self.path
    }
    await store.receive(.closeCompleted(wid, .success(.init()))) {
      $0.mutating.remove(wid)
    }
  }

  @Test
  func markReadyDispatchesGhClient() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.markReady = { prNumber, _ in #expect(prNumber == 11) }
    }
    await store.send(.markReadyRequested(wid, prNumber: 11, worktreePath: Self.path)) {
      $0.mutating.insert(wid)
      $0.worktreePaths[wid] = Self.path
    }
    await store.receive(.markReadyCompleted(wid, .success(.init()))) {
      $0.mutating.remove(wid)
    }
  }

  @Test
  func rerunFailedJobsDispatchesGhClient() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.rerunFailedJobs = { runID, _ in #expect(runID == 123) }
    }
    await store.send(.rerunFailedJobsRequested(wid, runID: 123, worktreePath: Self.path)) {
      $0.mutating.insert(wid)
      $0.worktreePaths[wid] = Self.path
    }
    await store.receive(.rerunFailedJobsCompleted(wid, .success(.init()))) {
      $0.mutating.remove(wid)
    }
  }

  @Test
  func rerunFailedJobsFailurePopulatesLastError() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.rerunFailedJobs = { _, _ in throw GitHubError.network("dns fail") }
    }
    await store.send(.rerunFailedJobsRequested(wid, runID: 1, worktreePath: Self.path)) {
      $0.mutating.insert(wid)
      $0.worktreePaths[wid] = Self.path
    }
    await store.receive {
      if case .rerunFailedJobsCompleted(let w, .failure) = $0, w == wid { return true }
      return false
    } assert: {
      $0.mutating.remove(wid)
      $0.lastError[wid] = .network("dns fail")
    }
  }

  // MARK: - state helper

  @Test
  func worktreeForPRNumberResolvesFromSnapshots() {
    var state = GitHubFeature.State()
    let wid = WorktreeID()
    state.snapshots[wid] = Self.stubSnapshot(number: 42)
    #expect(state.worktree(for: 42) == wid)
    #expect(state.worktree(for: 99) == nil)
  }

  // MARK: - Fixtures

  private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
  private static let path = URL(fileURLWithPath: "/tmp/touch-code-test")

  private static func stubSnapshot(
    number: Int = 1,
    title: String = "Test PR",
    state: PullRequestState = .open,
    headRefName: String = "feature/test"
  ) -> PullRequestSnapshot {
    PullRequestSnapshot(
      number: number,
      title: title,
      state: state,
      isDraft: false,
      headRefName: headRefName,
      author: "gump",
      additions: 0,
      deletions: 0,
      commitCount: 1,
      mergeable: .mergeable,
      url: URL(string: "https://github.com/w/r/pull/\(number)")!,
      updatedAt: fixedDate
    )
  }

  private static func stubRun(runID: Int64) -> WorkflowRun {
    WorkflowRun(
      databaseID: runID,
      name: "CI",
      status: .completed,
      conclusion: .success,
      headBranch: "feature/test",
      headSHA: "abc",
      runNumber: 1,
      updatedAt: fixedDate,
      url: URL(string: "https://github.com/w/r/actions/runs/\(runID)")!
    )
  }

  private static func makeStore(
    initialState: GitHubFeature.State = .init(),
    customize: @MainActor (inout GitHubClient) -> Void = { _ in },
    customizeGit: @MainActor (inout GitServiceClient) -> Void = { _ in }
  ) -> TestStore<GitHubFeature.State, GitHubFeature.Action> {
    TestStore(initialState: initialState) {
      GitHubFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
      var client = GitHubClient.testValue
      customize(&client)
      $0[GitHubClient.self] = client
      var git = GitServiceClient.testValue
      customizeGit(&git)
      $0[GitServiceClient.self] = git
    }
  }

  // MARK: - v2 project-batched fetch (0013 M4)

  @Test
  func projectActivatedWithEmptyBranchesReturnsEmptyBatch() async {
    let projectID = ProjectID()
    let gitRoot = URL(fileURLWithPath: "/tmp/test-repo")
    let store = Self.makeStore { _ in
    } customizeGit: { git in
      git.remoteInfo = { _ in
        RemoteInfo(host: "github.com", owner: "w", repo: "r")
      }
    }
    await store.send(.projectActivated(projectID, gitRoot: gitRoot, worktreeBranches: [])) {
      $0.inFlightFetchProjects.insert(projectID)
      $0.projectGitRoots[projectID] = gitRoot
    }
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, _, .success(let batched)) = action else { return false }
      return pid == projectID && batched.byBranch.isEmpty
    } assert: {
      $0.inFlightFetchProjects.remove(projectID)
      $0.snapshotsByProject[projectID] = BatchedPullRequests(
        host: "github.com", owner: "w", repo: "r",
        byBranch: [:], seenBranches: [], fetchedAt: Self.fixedDate
      )
    }
  }

  @Test
  func projectActivatedFiresBatchFetchAndProjectsSnapshots() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/test-repo")
    let pair = GitHubFeature.Action.WorktreeBranchPair(
      worktreeID: wid, branch: "feature/github01"
    )
    let returnedSnapshot = Self.stubSnapshot(number: 39, headRefName: "feature/github01")
    let store = Self.makeStore { client in
      client.batchPullRequests = { _, _, _, _ in
        ["feature/github01": returnedSnapshot]
      }
    } customizeGit: { git in
      git.remoteInfo = { _ in
        RemoteInfo(host: "github.com", owner: "wanggang316", repo: "touch-code")
      }
    }
    await store.send(.projectActivated(projectID, gitRoot: gitRoot, worktreeBranches: [pair])) {
      $0.inFlightFetchProjects.insert(projectID)
      $0.projectGitRoots[projectID] = gitRoot
    }
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, let pairs, .success) = action else { return false }
      return pid == projectID && pairs == [pair]
    } assert: {
      $0.inFlightFetchProjects.remove(projectID)
      $0.snapshotsByProject[projectID] = BatchedPullRequests(
        host: "github.com", owner: "wanggang316", repo: "touch-code",
        byBranch: ["feature/github01": returnedSnapshot],
        seenBranches: ["feature/github01"],
        fetchedAt: Self.fixedDate
      )
      // Projected into the per-Worktree map for v1-view compatibility during M4–M5.
      $0.snapshots[wid] = returnedSnapshot
      $0.snapshotLoadedAt[wid] = Self.fixedDate
    }
  }

  @Test
  func projectActivatedWhileInFlightQueuesRefresh() async {
    let projectID = ProjectID()
    var seed = GitHubFeature.State()
    seed.inFlightFetchProjects.insert(projectID)
    seed.projectGitRoots[projectID] = URL(fileURLWithPath: "/tmp/r")
    let store = Self.makeStore(initialState: seed)
    await store.send(
      .projectActivated(
        projectID, gitRoot: URL(fileURLWithPath: "/tmp/r"), worktreeBranches: []
      )
    ) {
      $0.queuedRefreshByProject.insert(projectID)
    }
  }

  @Test
  func projectBatchLoadedFailurePopulatesLastError() async {
    let projectID = ProjectID()
    var seed = GitHubFeature.State()
    seed.inFlightFetchProjects.insert(projectID)
    let store = Self.makeStore(initialState: seed)
    await store.send(
      .projectBatchLoaded(
        projectID, worktreeBranches: [], .failure(GitHubError.network("DNS"))
      )
    ) {
      $0.inFlightFetchProjects.remove(projectID)
      $0.lastErrorByProject[projectID] = .network("DNS")
    }
  }

  @Test
  func projectActivatedSkipsWhenCachedBranchSetMatches() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/r")
    let pair = GitHubFeature.Action.WorktreeBranchPair(
      worktreeID: wid, branch: "feature/github01"
    )
    var seed = GitHubFeature.State()
    seed.snapshotsByProject[projectID] = BatchedPullRequests(
      host: "github.com", owner: "w", repo: "r",
      byBranch: [:], seenBranches: ["feature/github01"], fetchedAt: Self.fixedDate
    )
    let store = Self.makeStore(initialState: seed) { client in
      client.batchPullRequests = { _, _, _, _ in
        Issue.record("batchPullRequests must not be called when cache is valid")
        return [:]
      }
    }
    await store.send(.projectActivated(projectID, gitRoot: gitRoot, worktreeBranches: [pair]))
  }

  @Test
  func worktreeBranchChangedKicksProjectRefetch() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/r")
    let pair = GitHubFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "new-branch")
    let store = Self.makeStore { client in
      client.batchPullRequests = { _, _, _, _ in [:] }
    } customizeGit: { git in
      git.remoteInfo = { _ in
        RemoteInfo(host: "github.com", owner: "w", repo: "r")
      }
    }
    await store.send(
      .worktreeBranchChanged(
        wid, newBranch: "new-branch",
        projectID: projectID, gitRoot: gitRoot, worktreeBranches: [pair]
      )
    ) {
      $0.inFlightFetchProjects.insert(projectID)
      $0.projectGitRoots[projectID] = gitRoot
    }
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, _, .success(let batched)) = action else { return false }
      return pid == projectID && batched.byBranch.isEmpty
    } assert: {
      $0.inFlightFetchProjects.remove(projectID)
      $0.snapshotsByProject[projectID] = BatchedPullRequests(
        host: "github.com", owner: "w", repo: "r",
        byBranch: [:], seenBranches: ["new-branch"], fetchedAt: Self.fixedDate
      )
    }
  }
}
