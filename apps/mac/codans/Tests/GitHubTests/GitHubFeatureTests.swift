import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

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

  // MARK: - popover

  @Test
  func presentPopoverWithCachedSnapshotFetchesWorkflowRun() async {
    // The per-popover `gh pr checks` fetch was retired; check data now travels
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
    // Post-mutation refresh is now project-level: it resolves the owning
    // Project from `projectByWorktree`. This Worktree was never part of a batched
    // fetch, so `postMutationRefresh` returns `.none` and the only follow-up is the
    // delegate. A separate test covers the delayed project refresh when the mapping
    // exists (`postMutationSchedulesDelayedProjectRefresh`).
    let wid = WorktreeID()
    let snap = Self.stubSnapshot(number: 99, state: .open, headRefName: "feature/test")
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = snap
    let store = Self.makeStore(initialState: seed) { client in
      client.merge = { prNumber, strategy, _ in
        #expect(prNumber == 99)
        #expect(strategy == .squash)
      }
    }
    await store.send(.mergeRequested(wid, prNumber: 99, strategy: .squash, worktreePath: Self.path)) {
      $0.mutating.insert(wid)
      $0.worktreePaths[wid] = Self.path
    }
    await store.receive(.mergeCompleted(wid, prNumber: 99, .success(.init()))) {
      $0.mutating.remove(wid)
    }
    await store.receive(.delegate(.pullRequestMerged(wid, snapshot: snap)))
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
  private static let path = URL(fileURLWithPath: "/tmp/codans-test")

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
    clock: any Clock<Duration> = ImmediateClock(),
    customize: @MainActor (inout GitHubClient) -> Void = { _ in },
    customizeGit: @MainActor (inout GitServiceClient) -> Void = { _ in }
  ) -> TestStore<GitHubFeature.State, GitHubFeature.Action> {
    TestStore(initialState: initialState) {
      GitHubFeature()
    } withDependencies: {
      $0.date = .constant(fixedDate)
      $0.continuousClock = clock
      var client = GitHubClient.testValue
      customize(&client)
      $0[GitHubClient.self] = client
      var git = GitServiceClient.testValue
      customizeGit(&git)
      $0[GitServiceClient.self] = git
    }
  }

  // MARK: - v2 project-batched fetch

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
      $0.projectWorktreePairs[projectID] = []
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
        RemoteInfo(host: "github.com", owner: "wanggang316", repo: "codans")
      }
    }
    await store.send(.projectActivated(projectID, gitRoot: gitRoot, worktreeBranches: [pair])) {
      $0.projectWorktreePairs[projectID] = [pair]
      $0.projectByWorktree[wid] = projectID
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(wid)
      $0.projectGitRoots[projectID] = gitRoot
    }
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, let pairs, .success) = action else { return false }
      return pid == projectID && pairs == [pair]
    } assert: {
      $0.inFlightFetchProjects.remove(projectID)
      $0.loading.remove(wid)
      $0.snapshotsByProject[projectID] = BatchedPullRequests(
        host: "github.com", owner: "wanggang316", repo: "codans",
        byBranch: ["feature/github01": returnedSnapshot],
        seenBranches: ["feature/github01"],
        fetchedAt: Self.fixedDate
      )
      // Projected into the per-Worktree map for v1-view compatibility.
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
      $0.projectWorktreePairs[projectID] = []
      $0.queuedRefreshByProject.insert(projectID)
    }
  }

  @Test
  func projectBatchLoadedFailurePopulatesLastError() async {
    let projectID = ProjectID()
    var seed = GitHubFeature.State()
    seed.inFlightFetchProjects.insert(projectID)
    // `enqueueProjectFetch` writes this before dispatching, so every real
    // `projectBatchLoaded` has it. Its absence is how the reducer recognises
    // a Project pruned mid-flight.
    seed.projectGitRoots[projectID] = URL(fileURLWithPath: "/repo")
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
  func pollTargetChangedArmsTickThenFetchesOnAdvance() async {
    let clock = TestClock()
    let projectID = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/test-repo")
    let pair = GitHubFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")
    let returnedSnapshot = Self.stubSnapshot(number: 7, headRefName: "feature/x")
    let store = Self.makeStore(clock: clock) { client in
      client.batchPullRequests = { _, _, _, _ in ["feature/x": returnedSnapshot] }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "w", repo: "r") }
    }
    // Arm only — retargeting never fetches immediately (projectActivated owns that).
    await store.send(.pollTargetChanged(projectID, gitRoot: gitRoot, worktreeBranches: [pair])) {
      $0.pollTarget = projectID
      $0.projectGitRoots[projectID] = gitRoot
      $0.projectWorktreePairs[projectID] = [pair]
      $0.projectByWorktree[wid] = projectID
    }
    // No cached batch yet → idle cadence (60 s). Advancing fires exactly one tick.
    await clock.advance(by: .seconds(60))
    await store.receive(.pollTick(projectID)) {
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(wid)
    }
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, _, .success) = action else { return false }
      return pid == projectID
    } assert: {
      $0.inFlightFetchProjects.remove(projectID)
      $0.loading.remove(wid)
      $0.snapshotsByProject[projectID] = BatchedPullRequests(
        host: "github.com", owner: "w", repo: "r",
        byBranch: ["feature/x": returnedSnapshot],
        seenBranches: ["feature/x"], fetchedAt: Self.fixedDate
      )
      $0.snapshots[wid] = returnedSnapshot
      $0.snapshotLoadedAt[wid] = Self.fixedDate
    }
    // Tear down the re-armed timer so the store has no effect left in flight.
    await store.send(.pollTargetChanged(nil, gitRoot: nil, worktreeBranches: [])) {
      $0.pollTarget = nil
    }
  }

  @Test
  func pollPausesWhenTargetNil() async {
    let clock = TestClock()
    let projectID = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/r")
    let pair = GitHubFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "b")
    let store = Self.makeStore(clock: clock) { client in
      client.batchPullRequests = { _, _, _, _ in
        Issue.record("no fetch should fire once the poll is paused")
        return [:]
      }
    }
    await store.send(.pollTargetChanged(projectID, gitRoot: gitRoot, worktreeBranches: [pair])) {
      $0.pollTarget = projectID
      $0.projectGitRoots[projectID] = gitRoot
      $0.projectWorktreePairs[projectID] = [pair]
      $0.projectByWorktree[wid] = projectID
    }
    await store.send(.pollTargetChanged(nil, gitRoot: nil, worktreeBranches: [])) {
      $0.pollTarget = nil
    }
    // The armed tick was cancelled; advancing well past the cadence fires nothing.
    await clock.advance(by: .seconds(120))
  }

  @Test
  func pollCadenceIsFastWhenAnyCheckIsRunning() {
    let batched = BatchedPullRequests(
      host: "github.com", owner: "w", repo: "r",
      byBranch: ["b": Self.snapshot(state: .open, checkStatus: .inProgress, merge: .clean)],
      seenBranches: ["b"], fetchedAt: Self.fixedDate
    )
    #expect(GitHubFeature.pollCadence(for: batched) == GitHubFeature.pollCadenceActive)
  }

  @Test
  func pollCadenceIsFastWhenMergeStateUnknown() {
    let batched = BatchedPullRequests(
      host: "github.com", owner: "w", repo: "r",
      byBranch: ["b": Self.snapshot(state: .open, checkStatus: .completed, merge: .unknown)],
      seenBranches: ["b"], fetchedAt: Self.fixedDate
    )
    #expect(GitHubFeature.pollCadence(for: batched) == GitHubFeature.pollCadenceActive)
  }

  @Test
  func pollCadenceIsSlowWhenSettled() {
    let batched = BatchedPullRequests(
      host: "github.com", owner: "w", repo: "r",
      byBranch: ["b": Self.snapshot(state: .open, checkStatus: .completed, merge: .clean)],
      seenBranches: ["b"], fetchedAt: Self.fixedDate
    )
    #expect(GitHubFeature.pollCadence(for: batched) == GitHubFeature.pollCadenceIdle)
  }

  @Test
  func pollCadenceIsSlowWhenNoCachedBatch() {
    #expect(GitHubFeature.pollCadence(for: nil) == GitHubFeature.pollCadenceIdle)
  }

  @Test
  func postMutationSchedulesDelayedProjectRefresh() async {
    let clock = TestClock()
    let projectID = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/r")
    let pair = GitHubFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")
    let snap = Self.stubSnapshot(number: 99, state: .open, headRefName: "feature/x")
    var seed = GitHubFeature.State()
    seed.snapshots[wid] = snap
    seed.projectByWorktree[wid] = projectID
    seed.projectGitRoots[projectID] = gitRoot
    seed.projectWorktreePairs[projectID] = [pair]
    let store = Self.makeStore(initialState: seed, clock: clock) { client in
      client.merge = { _, _, _ in }
      client.batchPullRequests = { _, _, _, _ in ["feature/x": snap] }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "w", repo: "r") }
    }
    await store.send(.mergeRequested(wid, prNumber: 99, strategy: .squash, worktreePath: Self.path)) {
      $0.mutating.insert(wid)
      $0.worktreePaths[wid] = Self.path
    }
    await store.receive(.mergeCompleted(wid, prNumber: 99, .success(.init()))) {
      $0.mutating.remove(wid)
    }
    await store.receive(.delegate(.pullRequestMerged(wid, snapshot: snap)))
    // Delayed 2 s so GitHub settles the write before we read it back.
    await clock.advance(by: .seconds(2))
    await store.receive(
      .projectRefreshRequested(projectID, gitRoot: gitRoot, worktreeBranches: [pair])
    ) {
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(wid)
    }
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, _, .success) = action else { return false }
      return pid == projectID
    } assert: {
      $0.inFlightFetchProjects.remove(projectID)
      $0.loading.remove(wid)
      $0.snapshotsByProject[projectID] = BatchedPullRequests(
        host: "github.com", owner: "w", repo: "r",
        byBranch: ["feature/x": snap], seenBranches: ["feature/x"], fetchedAt: Self.fixedDate
      )
      $0.snapshots[wid] = snap
      $0.snapshotLoadedAt[wid] = Self.fixedDate
    }
  }

  // MARK: - catalog membership

  @Test
  func seedFromCacheDropsProjectsAbsentFromTheCatalog() async {
    let live = ProjectID()
    let dead = ProjectID()
    let wid = WorktreeID()
    let snap = Self.snapshot(state: .open, checkStatus: .completed, merge: .clean)
    let batched = { (branch: String) in
      BatchedPullRequests(
        host: "github.com", owner: "w", repo: "r",
        byBranch: [branch: snap], seenBranches: [branch], fetchedAt: Self.fixedDate
      )
    }
    let store = Self.makeStore()

    await store.send(
      .seedFromCache(
        cached: [live: batched("main"), dead: batched("old")],
        branchPairsByProject: [
          live: [.init(worktreeID: wid, branch: "main")]
        ],
        liveProjectIDs: [live]
      )
    ) {
      // The dead Project never enters state, so the next successful fetch
      // writes a cache file without it.
      $0.snapshotsByProject[live] = batched("main")
      $0.snapshots[wid] = snap
      $0.snapshotLoadedAt[wid] = Self.fixedDate
    }
  }

  @Test
  func pruneToCatalogDropsDeadKeysAndPausesThePoll() async {
    let live = ProjectID()
    let dead = ProjectID()
    let liveWID = WorktreeID()
    let deadWID = WorktreeID()
    let snap = Self.snapshot(state: .open, checkStatus: .completed, merge: .clean)
    var seed = GitHubFeature.State()
    seed.snapshots = [liveWID: snap, deadWID: snap]
    seed.snapshotLoadedAt = [liveWID: Self.fixedDate, deadWID: Self.fixedDate]
    seed.worktreePaths = [
      liveWID: URL(fileURLWithPath: "/repo"), deadWID: URL(fileURLWithPath: "/gone"),
    ]
    seed.projectByWorktree = [liveWID: live, deadWID: dead]
    seed.mutating = [deadWID]
    seed.projectGitRoots = [
      live: URL(fileURLWithPath: "/repo"), dead: URL(fileURLWithPath: "/gone"),
    ]
    seed.projectWorktreePairs = [
      live: [.init(worktreeID: liveWID, branch: "main")],
      dead: [.init(worktreeID: deadWID, branch: "old")],
    ]
    seed.inFlightFetchProjects = [dead]
    seed.queuedRefreshByProject = [dead]
    seed.pollTarget = dead
    let store = Self.makeStore(initialState: seed)

    await store.send(
      .pruneToCatalog(projectIDs: [live], worktreeIDs: [liveWID])
    ) {
      $0.snapshots = [liveWID: snap]
      $0.snapshotLoadedAt = [liveWID: Self.fixedDate]
      $0.worktreePaths = [liveWID: URL(fileURLWithPath: "/repo")]
      $0.projectByWorktree = [liveWID: live]
      $0.mutating = []
      $0.projectGitRoots = [live: URL(fileURLWithPath: "/repo")]
      $0.projectWorktreePairs = [live: [.init(worktreeID: liveWID, branch: "main")]]
      $0.inFlightFetchProjects = []
      $0.queuedRefreshByProject = []
      // A poll left aimed at a removed Project keeps shelling out
      // `gh api graphql` against a repository the user unregistered, and each
      // success writes it straight back into the on-disk cache.
      $0.pollTarget = nil
    }
  }

  @Test
  func pruneCancelsAnInFlightFetchForARemovedProject() async {
    let dead = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/gone")
    let pair = GitHubFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "main")
    let gate = Gate()
    let snap = Self.stubSnapshot(number: 1, headRefName: "main")
    let store = Self.makeStore { client in
      client.batchPullRequests = { _, _, _, _ in
        await gate.wait()
        return ["main": snap]
      }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "w", repo: "r") }
    }

    await store.send(.projectActivated(dead, gitRoot: gitRoot, worktreeBranches: [pair])) {
      $0.projectGitRoots[dead] = gitRoot
      $0.projectWorktreePairs[dead] = [pair]
      $0.projectByWorktree[wid] = dead
      $0.loading.insert(wid)
      $0.inFlightFetchProjects.insert(dead)
    }

    // The Project leaves the catalog while `gh api graphql` is still running.
    await store.send(.pruneToCatalog(projectIDs: [], worktreeIDs: [])) {
      $0.projectGitRoots = [:]
      $0.projectWorktreePairs = [:]
      $0.projectByWorktree = [:]
      $0.loading = []
      $0.inFlightFetchProjects = []
    }

    // Releasing the fetch must produce nothing: TestStore fails the test if a
    // `projectBatchLoaded` arrives unasserted.
    gate.open()
    await store.finish()
  }

  @Test
  func aLateSuccessForAPrunedProjectIsNotWrittenBack() async {
    let dead = ProjectID()
    let wid = WorktreeID()
    let pair = GitHubFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "main")
    var seed = GitHubFeature.State()
    seed.projectGitRoots = [dead: URL(fileURLWithPath: "/gone")]
    seed.projectWorktreePairs = [dead: [pair]]
    seed.projectByWorktree = [wid: dead]
    seed.inFlightFetchProjects = [dead]
    seed.loading = [wid]
    let store = Self.makeStore(initialState: seed)

    await store.send(.pruneToCatalog(projectIDs: [], worktreeIDs: [])) {
      $0.projectGitRoots = [:]
      $0.projectWorktreePairs = [:]
      $0.projectByWorktree = [:]
      $0.inFlightFetchProjects = []
      $0.loading = []
    }

    // Cancellation is cooperative, so a result already dispatched can still
    // land. Only `inFlightFetchProjects` and `loading` may move — restoring
    // the batch would undo the prune and re-persist a dead Project to disk.
    let batched = BatchedPullRequests(
      host: "github.com", owner: "w", repo: "r",
      byBranch: ["main": Self.stubSnapshot(number: 1, headRefName: "main")],
      seenBranches: ["main"], fetchedAt: Self.fixedDate
    )
    await store.send(
      .projectBatchLoaded(dead, worktreeBranches: [pair], .success(batched))
    )
  }

  @Test
  func aLateFailureForAPrunedProjectDoesNotRestoreItsError() async {
    let dead = ProjectID()
    let wid = WorktreeID()
    let pair = GitHubFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "main")
    var seed = GitHubFeature.State()
    seed.projectGitRoots = [dead: URL(fileURLWithPath: "/gone")]
    seed.inFlightFetchProjects = [dead]
    seed.loading = [wid]
    let store = Self.makeStore(initialState: seed)

    await store.send(.pruneToCatalog(projectIDs: [], worktreeIDs: [])) {
      $0.projectGitRoots = [:]
      $0.inFlightFetchProjects = []
      $0.loading = []
    }
    await store.send(
      .projectBatchLoaded(dead, worktreeBranches: [pair], .failure(GitHubError.network("DNS")))
    )
  }

  @Test
  func aLateSuccessSkipsWorktreesRemovedWhileTheProjectSurvived() async {
    let live = ProjectID()
    let keptWID = WorktreeID()
    let goneWID = WorktreeID()
    let kept = GitHubFeature.Action.WorktreeBranchPair(worktreeID: keptWID, branch: "main")
    let gone = GitHubFeature.Action.WorktreeBranchPair(worktreeID: goneWID, branch: "old")
    var seed = GitHubFeature.State()
    seed.projectGitRoots = [live: URL(fileURLWithPath: "/repo")]
    seed.projectWorktreePairs = [live: [kept, gone]]
    seed.projectByWorktree = [keptWID: live, goneWID: live]
    seed.inFlightFetchProjects = [live]
    seed.loading = [keptWID, goneWID]
    let store = Self.makeStore(initialState: seed)

    await store.send(.pruneToCatalog(projectIDs: [live], worktreeIDs: [keptWID])) {
      $0.projectByWorktree = [keptWID: live]
      $0.loading = [keptWID]
      // Nested pairs are pruned too, so a re-issued fetch cannot name the
      // removed Worktree.
      $0.projectWorktreePairs[live] = [kept]
    }

    let keptSnap = Self.stubSnapshot(number: 1, headRefName: "main")
    let goneSnap = Self.stubSnapshot(number: 2, headRefName: "old")
    let batched = BatchedPullRequests(
      host: "github.com", owner: "w", repo: "r",
      byBranch: ["main": keptSnap, "old": goneSnap],
      seenBranches: ["main", "old"], fetchedAt: Self.fixedDate
    )
    await store.send(
      .projectBatchLoaded(live, worktreeBranches: [kept, gone], .success(batched))
    ) {
      $0.inFlightFetchProjects = []
      $0.loading = []
      $0.lastErrorByProject[live] = nil
      $0.snapshotsByProject[live] = batched
      // Only the surviving Worktree is projected; `pairs` was captured
      // before the removal and still names the dead one.
      $0.snapshots[keptWID] = keptSnap
      $0.snapshotLoadedAt[keptWID] = Self.fixedDate
      $0.lastError[keptWID] = nil
    }
  }

  @Test
  func aQueuedRefreshDoesNotReviveAWorktreeRemovedMidFlight() async {
    let project = ProjectID()
    let keptWID = WorktreeID()
    let goneWID = WorktreeID()
    let kept = GitHubFeature.Action.WorktreeBranchPair(worktreeID: keptWID, branch: "main")
    let gone = GitHubFeature.Action.WorktreeBranchPair(worktreeID: goneWID, branch: "old")
    let gitRoot = URL(fileURLWithPath: "/repo")
    let keptSnap = Self.stubSnapshot(number: 1, headRefName: "main")
    let goneSnap = Self.stubSnapshot(number: 2, headRefName: "old")
    let gate = Gate()
    let store = Self.makeStore { client in
      client.batchPullRequests = { _, _, _, branches in
        await gate.wait()
        var out: [String: PullRequestSnapshot] = [:]
        if branches.contains("main") { out["main"] = keptSnap }
        if branches.contains("old") { out["old"] = goneSnap }
        return out
      }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", owner: "w", repo: "r") }
    }

    // A fetch for both Worktrees goes in flight.
    await store.send(
      .projectActivated(project, gitRoot: gitRoot, worktreeBranches: [kept, gone])
    ) {
      $0.projectGitRoots[project] = gitRoot
      $0.projectWorktreePairs[project] = [kept, gone]
      $0.projectByWorktree = [keptWID: project, goneWID: project]
      $0.loading = [keptWID, goneWID]
      $0.inFlightFetchProjects = [project]
    }

    // A second refresh queues behind it, then one Worktree is removed.
    await store.send(
      .projectRefreshRequested(project, gitRoot: gitRoot, worktreeBranches: [kept, gone])
    ) {
      $0.queuedRefreshByProject = [project]
    }
    await store.send(.pruneToCatalog(projectIDs: [project], worktreeIDs: [keptWID])) {
      $0.projectWorktreePairs[project] = [kept]
      $0.projectByWorktree = [keptWID: project]
      $0.loading = [keptWID]
    }

    gate.open()

    // The in-flight result lands and drains the queued refresh. Re-issuing
    // with the captured pairs would put the removed Worktree back into
    // `projectByWorktree` and `loading`, after which the second result would
    // sail past the completion guards and restore its snapshot.
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, _, .success) = action else { return false }
      return pid == project
    } assert: {
      $0.inFlightFetchProjects = []
      $0.loading = []
      $0.lastErrorByProject[project] = nil
      $0.snapshotsByProject[project] = BatchedPullRequests(
        host: "github.com", owner: "w", repo: "r",
        byBranch: ["main": keptSnap, "old": goneSnap],
        seenBranches: ["main", "old"], fetchedAt: Self.fixedDate
      )
      $0.snapshots[keptWID] = keptSnap
      $0.snapshotLoadedAt[keptWID] = Self.fixedDate
      $0.lastError[keptWID] = nil
      $0.queuedRefreshByProject = []
    }
    await store.receive(
      .projectRefreshRequested(project, gitRoot: gitRoot, worktreeBranches: [kept])
    ) {
      $0.loading = [keptWID]
      $0.inFlightFetchProjects = [project]
    }
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, _, .success) = action else { return false }
      return pid == project
    } assert: {
      $0.inFlightFetchProjects = []
      $0.loading = []
      $0.snapshotsByProject[project] = BatchedPullRequests(
        host: "github.com", owner: "w", repo: "r",
        byBranch: ["main": keptSnap],
        seenBranches: ["main"], fetchedAt: Self.fixedDate
      )
    }

    #expect(store.state.projectByWorktree[goneWID] == nil)
    #expect(store.state.snapshots[goneWID] == nil)
    #expect(!store.state.loading.contains(goneWID))
    #expect(store.state.projectWorktreePairs[project] == [kept])
  }

  @Test
  func pruneToCatalogKeepsAPollWhoseProjectSurvived() async {
    let live = ProjectID()
    var seed = GitHubFeature.State()
    seed.pollTarget = live
    seed.projectGitRoots = [live: URL(fileURLWithPath: "/repo")]
    let store = Self.makeStore(initialState: seed)

    await store.send(.pruneToCatalog(projectIDs: [live], worktreeIDs: []))
  }

  /// One-shot gate so a test can hold a stubbed fetch open across other
  /// actions, then release it. Models a `gh api graphql` still running when
  /// the catalog mutates underneath it.
  private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        lock.lock()
        if opened {
          lock.unlock()
          c.resume()
          return
        }
        continuation = c
        lock.unlock()
      }
    }

    func open() {
      lock.lock()
      opened = true
      let pending = continuation
      continuation = nil
      lock.unlock()
      pending?.resume()
    }
  }

  /// Cadence-predicate fixture: an open/settled/in-flight snapshot in one line.
  private static func snapshot(
    state: PullRequestState,
    checkStatus: CheckStatus,
    merge: MergeStateStatus
  ) -> PullRequestSnapshot {
    PullRequestSnapshot(
      number: 1, title: "t", state: state, isDraft: false, headRefName: "b",
      author: "a", additions: 0, deletions: 0, commitCount: 1, mergeable: .mergeable,
      url: URL(string: "https://github.com/w/r/pull/1")!, updatedAt: fixedDate,
      checkRollup: [
        CheckResult(
          name: "build", status: checkStatus,
          conclusion: checkStatus == .completed ? .success : nil
        )
      ],
      mergeStateStatus: merge
    )
  }
}
