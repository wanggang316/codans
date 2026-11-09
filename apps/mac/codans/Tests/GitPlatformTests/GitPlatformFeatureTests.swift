import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// TestStore coverage for GitPlatformFeature. Exercises every action path with stubbed
/// GitPlatformClient closures. No network, no gh subprocess.
@MainActor
struct GitPlatformFeatureTests {
  // MARK: - availability

  @Test
  func onAppearProbesAvailabilityAndStoresResult() async {
    let store = Self.makeStore { client in
      client.availability = { kind in .available(host: kind.publicHost, user: "gump") }
    }
    await store.send(.onAppear)
    await store.receive {
      if case .availabilityProbed(let result, _) = $0, result[.github]?.isAvailable == true { return true }
      return false
    } assert: {
      $0.availability = [
        .github: .available(host: "github.com", user: "gump"), .gitlab: .available(host: "gitlab.com", user: "gump"),
      ]
      $0.availabilityProbedAt = Self.fixedDate
    }
  }

  @Test
  func onAppearWithinFreshnessWindowSkipsProbe() async {
    var seed = GitPlatformFeature.State()
    seed.availability = [
      .github: .available(host: "github.com", user: "gump"), .gitlab: .available(host: "gitlab.com", user: "gump"),
    ]
    seed.availabilityProbedAt = Self.fixedDate
    let store = Self.makeStore(initialState: seed) { client in
      client.availability = { _ in
        Issue.record("availability should not be called inside the 30 s window")
        return .unknown
      }
    }
    await store.send(.onAppear)
  }

  @Test
  func refreshAvailabilityAlwaysReprobes() async {
    var seed = GitPlatformFeature.State()
    seed.availability = [.github: .available(host: "github.com", user: "gump")]
    seed.availabilityProbedAt = Self.fixedDate
    let store = Self.makeStore(initialState: seed) { client in
      client.availability = { kind in .unavailable(reason: "\(kind.cliName) missing") }
    }
    await store.send(.refreshAvailabilityRequested) {
      $0.availabilityProbedAt = nil
    }
    await store.receive {
      if case .availabilityProbed(let result, _) = $0, result[.github]?.isAvailable == false { return true }
      return false
    } assert: {
      $0.availability = [.github: .unavailable(reason: "gh missing"), .gitlab: .unavailable(reason: "glab missing")]
      $0.availabilityProbedAt = Self.fixedDate
    }
  }

  /// The probe runs after the invalidation finishes; otherwise it can read the CLI path
  /// and logged-in hosts from before a `glab auth login` and cache them for 30 s.
  @Test
  func refreshAvailabilityProbesAfterTheInvalidationFinishes() async {
    let invalidated = LockIsolated(false)
    let probedBeforeInvalidation = LockIsolated(false)
    let store = Self.makeStore { client in
      client.invalidateResolution = {
        try? await Task.sleep(for: .milliseconds(100))
        invalidated.setValue(true)
      }
      client.availability = { _ in
        if !invalidated.value { probedBeforeInvalidation.setValue(true) }
        return .unknown
      }
    }
    store.exhaustivity = .off
    await store.send(.refreshAvailabilityRequested)
    await store.receive(\.availabilityProbed, timeout: .seconds(5))
    #expect(invalidated.value)
    #expect(!probedBeforeInvalidation.value)
  }

  // MARK: - popover

  @Test
  func presentPopoverSetsTargetWithoutFetching() async {
    // Checks and the rerun capability travel with the snapshot, so opening the
    // popover starts no Git Platform call.
    let wid = WorktreeID()
    var seed = GitPlatformFeature.State()
    seed.snapshots[wid] = Self.stubSnapshot(number: 42, headRefName: "feature/github01")
    let store = Self.makeStore(initialState: seed)
    await store.send(.presentPopover(wid)) {
      $0.popoverTarget = wid
    }
  }

  @Test
  func dismissPopoverClearsTarget() async {
    let wid = WorktreeID()
    var seed = GitPlatformFeature.State()
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
    var seed = GitPlatformFeature.State()
    seed.snapshots[wid] = snap
    let store = Self.makeStore(initialState: seed) { client in
      client.merge = { pullRequest, strategy, headSHA in
        #expect(pullRequest == Self.reference(99))
        #expect(strategy == .squash)
        #expect(headSHA == "abc123")
      }
    }
    await store.send(.mergeRequested(wid, Self.reference(99), strategy: .squash, headSHA: "abc123")) {
      $0.mutating.insert(wid)
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
      client.merge = { _, _, _ in throw GitPlatformError.mergeConflict }
    }
    await store.send(.mergeRequested(wid, Self.reference(1), strategy: .squash, headSHA: "abc123")) {
      $0.mutating.insert(wid)
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
    var seed = GitPlatformFeature.State()
    seed.mutating.insert(wid)
    let store = Self.makeStore(initialState: seed) { client in
      client.merge = { _, _, _ in
        Issue.record("merge must not be called when another mutation is in flight")
      }
    }
    await store.send(.mergeRequested(wid, Self.reference(1), strategy: .squash, headSHA: "abc123"))
  }

  @Test
  func closeDispatchesGhClient() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.close = { pullRequest in #expect(pullRequest == Self.reference(7)) }
    }
    await store.send(.closeRequested(wid, Self.reference(7))) {
      $0.mutating.insert(wid)
    }
    await store.receive(.closeCompleted(wid, .success(.init()))) {
      $0.mutating.remove(wid)
    }
  }

  @Test
  func markReadyDispatchesGhClient() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.markReady = { pullRequest in #expect(pullRequest == Self.reference(11)) }
    }
    await store.send(.markReadyRequested(wid, Self.reference(11))) {
      $0.mutating.insert(wid)
    }
    await store.receive(.markReadyCompleted(wid, .success(.init()))) {
      $0.mutating.remove(wid)
    }
  }

  @Test
  func rerunFailedChecksDispatchesGitPlatformClient() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.rerunFailedChecks = { pullRequest in #expect(pullRequest == Self.reference(123)) }
    }
    await store.send(.rerunFailedChecksRequested(wid, Self.reference(123))) {
      $0.mutating.insert(wid)
    }
    await store.receive(.rerunFailedChecksCompleted(wid, .success(.init()))) {
      $0.mutating.remove(wid)
    }
  }

  @Test
  func rerunFailedChecksFailurePopulatesLastError() async {
    let wid = WorktreeID()
    let store = Self.makeStore { client in
      client.rerunFailedChecks = { _ in throw GitPlatformError.network("dns fail") }
    }
    await store.send(.rerunFailedChecksRequested(wid, Self.reference(1))) {
      $0.mutating.insert(wid)
    }
    await store.receive {
      if case .rerunFailedChecksCompleted(let w, .failure) = $0, w == wid { return true }
      return false
    } assert: {
      $0.mutating.remove(wid)
      $0.lastError[wid] = .network("dns fail")
    }
  }

  // MARK: - head commit guard (ADR 0004 item 17)

  @Test
  func mergeWithoutHeadSHARefreshesTheUnitAndDoesNotMerge() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")
    let old = Self.stubSnapshot(number: 99, headRefName: "feature/x", headSHA: nil)
    let fresh = Self.stubSnapshot(number: 99, headRefName: "feature/x", headSHA: "def456")
    var seed = Self.unitSeed(projectID: projectID, pair: pair)
    seed.snapshots[wid] = old
    let store = Self.makeStore(initialState: seed) { client in
      client.merge = { _, _, _ in Issue.record("a merge without a head commit must not run") }
      client.batchPullRequests = { _, _ in ["feature/x": fresh] }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }
    await store.send(.mergeRequested(wid, Self.reference(99), strategy: .squash, headSHA: nil)) {
      $0.lastFetchStartedAt[projectID] = Self.fixedDate
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(wid)
    }
    await Self.receiveBatch(store, projectID: projectID, wid: wid, branch: "feature/x", snapshot: fresh)
  }

  @Test
  func headMovedRejectionShowsItsErrorAndRefreshesTheUnitAtOnce() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")
    let seen = Self.stubSnapshot(number: 99, headRefName: "feature/x", headSHA: "abc123")
    let moved = Self.stubSnapshot(number: 99, headRefName: "feature/x", headSHA: "def456")
    var seed = Self.unitSeed(projectID: projectID, pair: pair)
    seed.snapshots[wid] = seen
    let store = Self.makeStore(initialState: seed) { client in
      client.merge = { _, _, _ in throw GitPlatformError.headMoved }
      client.batchPullRequests = { _, _ in ["feature/x": moved] }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }
    await store.send(.mergeRequested(wid, Self.reference(99), strategy: .squash, headSHA: "abc123")) {
      $0.mutating.insert(wid)
    }
    // No 2 s delay: the fetch starts with the failure.
    await store.receive {
      if case .mergeCompleted(let w, 99, .failure) = $0, w == wid { return true }
      return false
    } assert: {
      $0.mutating.remove(wid)
      $0.lastError[wid] = .headMoved
      $0.headMovedMerges[wid] = .init(pullRequestNumber: 99, branch: "feature/x", refusedAt: Self.fixedDate)
      $0.lastFetchStartedAt[projectID] = Self.fixedDate
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(wid)
    }
    // The error stays through the refresh; the new head is underneath it.
    await Self.receiveBatch(store, projectID: projectID, wid: wid, branch: "feature/x", snapshot: moved) {
      $0.headMovedMerges[wid]?.isNewHeadRead = true
    }
    #expect(store.state.lastError[wid] == .headMoved)
    #expect(
      GitPlatformError.headMoved.userFacingMessage == "The branch has new commits. Review them, then merge again.")
    await store.send(.headMovedReviewed(wid)) {
      $0.lastError[wid] = nil
      $0.headMovedMerges[wid] = nil
    }
  }

  /// "Review" before the new head is read (the refresh failed or is still running) does
  /// not show the old snapshot: it reads the head again.
  @Test
  func reviewBeforeTheNewHeadIsReadReadsItAgain() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")
    let moved = Self.stubSnapshot(number: 99, headRefName: "feature/x", headSHA: "def456")
    var seed = Self.unitSeed(projectID: projectID, pair: pair)
    seed.snapshots[wid] = Self.stubSnapshot(number: 99, headRefName: "feature/x", headSHA: "abc123")
    let reads = LockIsolated(0)
    let store = Self.makeStore(initialState: seed) { client in
      client.merge = { _, _, _ in throw GitPlatformError.headMoved }
      client.batchPullRequests = { _, _ in
        reads.withValue { $0 += 1 }
        if reads.value == 1 { throw GitPlatformError.network("offline") }
        return ["feature/x": moved]
      }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }
    await store.send(.mergeRequested(wid, Self.reference(99), strategy: .squash, headSHA: "abc123")) {
      $0.mutating.insert(wid)
    }
    await store.receive {
      if case .mergeCompleted(_, 99, .failure) = $0 { return true }
      return false
    } assert: {
      $0.mutating.remove(wid)
      $0.lastError[wid] = .headMoved
      $0.headMovedMerges[wid] = .init(pullRequestNumber: 99, branch: "feature/x", refusedAt: Self.fixedDate)
      $0.lastFetchStartedAt[projectID] = Self.fixedDate
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(wid)
    }
    await store.receive {
      if case .projectBatchLoaded(_, _, .failure) = $0 { return true }
      return false
    } assert: {
      $0.inFlightFetchProjects.remove(projectID)
      $0.loading.remove(wid)
      $0.lastErrorByProject[projectID] = .network("offline")
    }
    // The read failed: the error and the old snapshot stay, and "Review" retries.
    #expect(store.state.headMovedMerges[wid]?.isNewHeadRead == false)
    await store.send(.headMovedReviewed(wid)) {
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(wid)
    }
    await Self.receiveBatch(store, projectID: projectID, wid: wid, branch: "feature/x", snapshot: moved) {
      $0.lastErrorByProject[projectID] = nil
      $0.headMovedMerges[wid]?.isNewHeadRead = true
    }
    await store.send(.headMovedReviewed(wid)) {
      $0.lastError[wid] = nil
      $0.headMovedMerges[wid] = nil
    }
  }

  /// A CLI error from the read after the refusal replaces `.headMoved` at the row. When
  /// the user fixes the CLI and the read succeeds, the row is back on `.headMoved` with the
  /// new head read, so "Review" shows it.
  @Test
  func aReadAfterACLIErrorRestoresTheHeadMovedReview() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")
    let moved = Self.stubSnapshot(number: 99, headRefName: "feature/x", headSHA: "def456")
    var seed = Self.unitSeed(projectID: projectID, pair: pair)
    seed.snapshots[wid] = Self.stubSnapshot(number: 99, headRefName: "feature/x", headSHA: "abc123")
    let reads = LockIsolated(0)
    let store = Self.makeStore(initialState: seed) { client in
      client.merge = { _, _, _ in throw GitPlatformError.headMoved }
      client.batchPullRequests = { _, _ in
        reads.withValue { $0 += 1 }
        if reads.value == 1 { throw GitPlatformError.notAuthenticated(.github, host: "github.com") }
        return ["feature/x": moved]
      }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }
    await store.send(.mergeRequested(wid, Self.reference(99), strategy: .squash, headSHA: "abc123")) {
      $0.mutating.insert(wid)
    }
    await store.receive {
      if case .mergeCompleted(_, 99, .failure) = $0 { return true }
      return false
    } assert: {
      $0.mutating.remove(wid)
      $0.lastError[wid] = .headMoved
      $0.headMovedMerges[wid] = .init(pullRequestNumber: 99, branch: "feature/x", refusedAt: Self.fixedDate)
      $0.lastFetchStartedAt[projectID] = Self.fixedDate
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(wid)
    }
    let cliError = GitPlatformError.notAuthenticated(.github, host: "github.com")
    await store.receive {
      if case .projectBatchLoaded(_, _, .failure) = $0 { return true }
      return false
    } assert: {
      $0.inFlightFetchProjects.remove(projectID)
      $0.loading.remove(wid)
      $0.lastErrorByProject[projectID] = cliError
      $0.lastError[wid] = cliError
    }
    // The CLI error's own button ("Run gh auth login") retries the read.
    await store.send(.worktreeRefreshRequested(wid)) {
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(wid)
    }
    await Self.receiveBatch(store, projectID: projectID, wid: wid, branch: "feature/x", snapshot: moved) {
      $0.lastErrorByProject[projectID] = nil
      $0.lastError[wid] = .headMoved
      $0.headMovedMerges[wid]?.isNewHeadRead = true
    }
    await store.send(.headMovedReviewed(wid)) {
      $0.lastError[wid] = nil
      $0.headMovedMerges[wid] = nil
    }
  }

  /// The refused merge belongs to one Pull Request: a refresh that shows another one (a
  /// new number on the branch) drops the error.
  @Test
  func aRefreshWithAnotherPullRequestDropsTheHeadMovedError() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")
    let other = Self.stubSnapshot(number: 100, headRefName: "feature/x", headSHA: "def456")
    var seed = Self.unitSeed(projectID: projectID, pair: pair)
    seed.snapshots[wid] = Self.stubSnapshot(number: 99, headRefName: "feature/x")
    seed.lastError[wid] = .headMoved
    seed.headMovedMerges[wid] = .init(pullRequestNumber: 99, branch: "feature/x", refusedAt: Self.fixedDate)
    let store = Self.makeStore(initialState: seed) { client in
      client.batchPullRequests = { _, _ in ["feature/x": other] }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }
    await store.send(.worktreeRefreshRequested(wid)) {
      $0.lastFetchStartedAt[projectID] = Self.fixedDate
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(wid)
    }
    await Self.receiveBatch(store, projectID: projectID, wid: wid, branch: "feature/x", snapshot: other) {
      $0.lastError[wid] = nil
      $0.headMovedMerges[wid] = nil
    }
  }

  /// A branch switch drops the error at once, before any read: it must not hide the
  /// Pull Request of the new branch.
  @Test
  func aBranchSwitchDropsTheHeadMovedError() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let old = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")
    let new = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/y")
    let snapY = Self.stubSnapshot(number: 7, headRefName: "feature/y")
    var seed = Self.unitSeed(projectID: projectID, pair: old)
    seed.snapshots[wid] = Self.stubSnapshot(number: 99, headRefName: "feature/x")
    seed.snapshotsByProject[projectID] = BatchedPullRequests(
      repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
      byBranch: ["feature/y": snapY], seenBranches: ["feature/x", "feature/y"], fetchedAt: Self.fixedDate)
    seed.lastError[wid] = .headMoved
    seed.headMovedMerges[wid] = .init(pullRequestNumber: 99, branch: "feature/x", refusedAt: Self.fixedDate)
    let store = Self.makeStore(initialState: seed)
    let unit = GitPlatformFeature.FetchUnit(
      projectID: projectID, gitRoot: URL(fileURLWithPath: "/tmp/r"), pairs: [new])
    await store.send(.pollUnitsChanged([unit], selected: [])) {
      $0.pollUnits = [projectID]
      $0.projectWorktreePairs[projectID] = [new]
      $0.snapshots[wid] = snapY
      $0.lastError[wid] = nil
      $0.headMovedMerges[wid] = nil
    }
  }

  @Test
  func headMovedReviewedKeepsOtherErrors() async {
    let wid = WorktreeID()
    var seed = GitPlatformFeature.State()
    seed.lastError[wid] = .mergeConflict
    let store = Self.makeStore(initialState: seed)
    await store.send(.headMovedReviewed(wid))
  }

  @Test
  func popoverOpenedOverASnapshotWithoutHeadSHARefreshesTheUnit() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")
    let fresh = Self.stubSnapshot(number: 99, headRefName: "feature/x", headSHA: "def456")
    var seed = Self.unitSeed(projectID: projectID, pair: pair)
    seed.snapshots[wid] = Self.stubSnapshot(number: 99, headRefName: "feature/x", headSHA: nil)
    let store = Self.makeStore(initialState: seed) { client in
      client.batchPullRequests = { _, _ in ["feature/x": fresh] }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }
    // Sent by the popover view itself, so the sidebar and the status bar both reach it.
    await store.send(.popoverOpened(wid)) {
      $0.lastFetchStartedAt[projectID] = Self.fixedDate
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(wid)
    }
    await Self.receiveBatch(store, projectID: projectID, wid: wid, branch: "feature/x", snapshot: fresh)
  }

  @Test
  func mergeIsOffUntilTheSnapshotHasAHeadCommit() {
    let snapshot = Self.stubSnapshot(headSHA: nil)
    #expect(
      WorktreePullRequestPopover.mergeDisabledReason(for: snapshot, strategy: .squash) == "Reading the head commit")
  }

  private static func unitSeed(
    projectID: ProjectID, pair: GitPlatformFeature.Action.WorktreeBranchPair
  ) -> GitPlatformFeature.State {
    var seed = GitPlatformFeature.State()
    seed.projectByWorktree[pair.worktreeID] = projectID
    seed.projectGitRoots[projectID] = URL(fileURLWithPath: "/tmp/r")
    seed.projectWorktreePairs[projectID] = [pair]
    return seed
  }

  private static func receiveBatch(
    _ store: TestStoreOf<GitPlatformFeature>, projectID: ProjectID, wid: WorktreeID, branch: String,
    snapshot: PullRequestSnapshot, also: @escaping (inout GitPlatformFeature.State) -> Void = { _ in }
  ) async {
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, _, .success) = action else { return false }
      return pid == projectID
    } assert: {
      $0.inFlightFetchProjects.remove(projectID)
      $0.loading.remove(wid)
      $0.snapshotsByProject[projectID] = BatchedPullRequests(
        repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
        byBranch: [branch: snapshot], seenBranches: [branch], fetchedAt: Self.fixedDate
      )
      $0.snapshots[wid] = snapshot
      $0.snapshotLoadedAt[wid] = Self.fixedDate
      also(&$0)
    }
  }

  // MARK: - state helper

  @Test
  func worktreeForPRNumberResolvesFromSnapshots() {
    var state = GitPlatformFeature.State()
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
    headRefName: String = "feature/test",
    headSHA: String? = "abc123"
  ) -> PullRequestSnapshot {
    PullRequestSnapshot(
      number: number,
      title: title,
      state: state,
      isDraft: false,
      headRefName: headRefName,
      headSHA: headSHA,
      author: "gump",
      additions: 0,
      deletions: 0,
      commitCount: 1,
      url: URL(string: "https://github.com/w/r/pull/\(number)")!,
      updatedAt: fixedDate,
      mergeState: PullRequestMergeState(status: .clean),
      mergeOptions: MergeStrategy.allCases.map { PullRequestMergeOption(strategy: $0, isEnabled: true) }
    )
  }

  nonisolated private static let repository = GitPlatformRepository(kind: .github, host: "github.com", path: "w/r")

  nonisolated private static func reference(_ number: Int) -> PullRequestReference {
    PullRequestReference(repository: repository, number: number)
  }

  private static func makeStore(
    initialState: GitPlatformFeature.State = .init(),
    clock: any Clock<Duration> = ImmediateClock(),
    date: DateGenerator = .constant(fixedDate),
    customize: @MainActor (inout GitPlatformClient) -> Void = { _ in },
    customizeGit: @MainActor (inout GitServiceClient) -> Void = { _ in }
  ) -> TestStore<GitPlatformFeature.State, GitPlatformFeature.Action> {
    TestStore(initialState: initialState) {
      GitPlatformFeature()
    } withDependencies: {
      $0.date = date
      $0.continuousClock = clock
      var client = GitPlatformClient.testValue
      // Resolves every remote like `github.com`; a test about unresolved remotes
      // overrides it.
      client.resolveRepository = { remote, _ in
        GitPlatformRepository(kind: .github, host: remote.host, path: remote.path)
      }
      customize(&client)
      $0[GitPlatformClient.self] = client
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
        RemoteInfo(host: "github.com", path: "w/r")
      }
    }
    await store.send(.projectActivated(projectID, gitRoot: gitRoot, worktreeBranches: [])) {
      $0.lastFetchStartedAt[projectID] = Self.fixedDate
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
        repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
        byBranch: [:], seenBranches: [], fetchedAt: Self.fixedDate
      )
    }
  }

  @Test
  func projectActivatedFiresBatchFetchAndProjectsSnapshots() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/test-repo")
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(
      worktreeID: wid, branch: "feature/github01"
    )
    let returnedSnapshot = Self.stubSnapshot(number: 39, headRefName: "feature/github01")
    let store = Self.makeStore { client in
      client.batchPullRequests = { _, _ in
        ["feature/github01": returnedSnapshot]
      }
    } customizeGit: { git in
      git.remoteInfo = { _ in
        RemoteInfo(host: "github.com", path: "wanggang316/codans")
      }
    }
    await store.send(.projectActivated(projectID, gitRoot: gitRoot, worktreeBranches: [pair])) {
      $0.lastFetchStartedAt[projectID] = Self.fixedDate
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
        repository: GitPlatformRepository(kind: .github, host: "github.com", path: "wanggang316/codans"),
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
  func aUnitWithNoGitPlatformStartsNoFetchAndShowsNoBadgeOrError() async {
    // `origin` is on a host no Git Platform serves (here a GitLab instance). The unit
    // resolves to no Git Platform: no batched fetch, no badge, no error — and the poll
    // and the focus catch-up leave it alone afterwards.
    let pid = ProjectID()
    let wid = WorktreeID()
    let root = URL(fileURLWithPath: "/repo")
    let pairs = [GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")]
    // A badge painted from an older cache must go too.
    var seed = GitPlatformFeature.State()
    seed.snapshots[wid] = Self.stubSnapshot(number: 5, headRefName: "feature/x")
    seed.snapshotsByProject[pid] = BatchedPullRequests(
      repository: Self.repository, byBranch: ["feature/x": Self.stubSnapshot(number: 5, headRefName: "feature/x")],
      seenBranches: ["feature/x"], fetchedAt: .distantPast
    )
    let store = Self.makeStore(initialState: seed) { client in
      client.resolveRepository = { remote, _ in
        #expect(remote.path == "group/sub/repo")
        return nil
      }
      client.batchPullRequests = { _, _ in
        Issue.record("a unit with no Git Platform must not fetch")
        return [:]
      }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "gitlab.example.com", path: "group/sub/repo") }
    }

    await store.send(.projectActivated(pid, gitRoot: root, worktreeBranches: pairs)) {
      $0.projectGitRoots[pid] = root
      $0.projectWorktreePairs[pid] = pairs
      $0.projectByWorktree[wid] = pid
      $0.inFlightFetchProjects = [pid]
      $0.lastFetchStartedAt[pid] = Self.fixedDate
    }
    await store.receive(.gitPlatformUnresolved(pid, worktreeBranches: pairs)) {
      $0.inFlightFetchProjects = []
      $0.unitsWithoutGitPlatform = [pid]
      $0.snapshots[wid] = nil
      $0.snapshotsByProject[pid] = nil
    }
    #expect(store.state.snapshots[wid] == nil)
    #expect(store.state.lastError[wid] == nil)
    #expect(store.state.lastErrorByProject[pid] == nil)

    let unit = GitPlatformFeature.FetchUnit(projectID: pid, gitRoot: root, pairs: pairs)
    await store.send(.pollUnitsChanged([unit], selected: [pid])) {
      $0.pollUnits = [pid]
      $0.selectedUnits = [pid]
    }
    await store.send(.appActiveChanged(true)) {
      $0.isPolling = true
    }
    await store.send(.appActiveChanged(false)) {
      $0.isPolling = false
    }
  }

  @Test
  func projectActivatedWhileInFlightQueuesRefresh() async {
    let projectID = ProjectID()
    var seed = GitPlatformFeature.State()
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
    var seed = GitPlatformFeature.State()
    seed.inFlightFetchProjects.insert(projectID)
    // `enqueueProjectFetch` writes this before dispatching, so every real
    // `projectBatchLoaded` has it. Its absence is how the reducer recognises
    // a Project pruned mid-flight.
    seed.projectGitRoots[projectID] = URL(fileURLWithPath: "/repo")
    let store = Self.makeStore(initialState: seed)
    await store.send(
      .projectBatchLoaded(
        projectID, worktreeBranches: [], .failure(GitPlatformError.network("DNS"))
      )
    ) {
      $0.inFlightFetchProjects.remove(projectID)
      $0.lastErrorByProject[projectID] = .network("DNS")
    }
  }

  /// A missing, logged-out, or outdated CLI shows its actionable message at each row's
  /// badge position (ADR 0004 item 15); the next successful fetch clears it.
  @Test(arguments: [
    GitPlatformError.cliNotInstalled(.gitlab), .notAuthenticated(.gitlab, host: "gitlab.com"),
    .cliOutdated(.gitlab, minVersion: "1.122.0"), .cliNotInstalled(.github),
  ])
  func cliErrorOfABatchShowsAtEveryRow(error: GitPlatformError) async {
    let projectID = ProjectID()
    let withPR = WorktreeID()
    let withoutPR = WorktreeID()
    let pairs = [
      GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: withPR, branch: "feat-open"),
      GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: withoutPR, branch: "feat-none"),
    ]
    var seed = GitPlatformFeature.State()
    seed.inFlightFetchProjects.insert(projectID)
    seed.projectGitRoots[projectID] = URL(fileURLWithPath: "/repo")
    seed.projectByWorktree = [withPR: projectID, withoutPR: projectID]
    let store = Self.makeStore(initialState: seed)
    await store.send(.projectBatchLoaded(projectID, worktreeBranches: pairs, .failure(error))) {
      $0.inFlightFetchProjects.remove(projectID)
      $0.lastErrorByProject[projectID] = error
      $0.lastError[withPR] = error
      $0.lastError[withoutPR] = error
    }
    let batch = BatchedPullRequests(
      repository: GitPlatformRepository(kind: .gitlab, host: "gitlab.com", path: "g/app"),
      byBranch: ["feat-open": Self.stubSnapshot(number: 1, headRefName: "feat-open")],
      seenBranches: ["feat-open", "feat-none"], fetchedAt: Self.fixedDate)
    await store.send(.projectBatchLoaded(projectID, worktreeBranches: pairs, .success(batch))) {
      $0.lastErrorByProject[projectID] = nil
      $0.lastError = [:]
      $0.snapshotsByProject[projectID] = batch
      $0.snapshots[withPR] = batch.byBranch["feat-open"]
      $0.snapshotLoadedAt[withPR] = Self.fixedDate
    }
  }

  /// Other batch errors stay on the unit; rows show no badge for them.
  @Test
  func nonCLIBatchErrorDoesNotReachTheRows() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    var seed = GitPlatformFeature.State()
    seed.inFlightFetchProjects.insert(projectID)
    seed.projectGitRoots[projectID] = URL(fileURLWithPath: "/repo")
    seed.projectByWorktree = [worktreeID: projectID]
    let store = Self.makeStore(initialState: seed)
    await store.send(
      .projectBatchLoaded(
        projectID, worktreeBranches: [.init(worktreeID: worktreeID, branch: "b")], .failure(GitPlatformError.timeout))
    ) {
      $0.inFlightFetchProjects.remove(projectID)
      $0.lastErrorByProject[projectID] = .timeout
    }
  }

  @Test
  func projectActivatedSkipsWhenCachedBranchSetMatches() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/r")
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(
      worktreeID: wid, branch: "feature/github01"
    )
    var seed = GitPlatformFeature.State()
    seed.snapshotsByProject[projectID] = BatchedPullRequests(
      repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
      byBranch: [:], seenBranches: ["feature/github01"], fetchedAt: Self.fixedDate
    )
    let store = Self.makeStore(initialState: seed) { client in
      client.batchPullRequests = { _, _ in
        Issue.record("batchPullRequests must not be called when cache is valid")
        return [:]
      }
    }
    await store.send(.projectActivated(projectID, gitRoot: gitRoot, worktreeBranches: [pair]))
  }

  /// The spinner means "nothing known yet": a refresh over a cached batch
  /// leaves `loading` alone, so PR-less rows do not flip to "loading" on
  /// every poll tick while the rows already show what the cache knows.
  @Test
  func aRefreshOverACachedBatchDoesNotMarkLoading() async {
    let projectID = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/test-repo")
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "main")
    let cached = BatchedPullRequests(
      repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
      byBranch: [:], seenBranches: ["main"], fetchedAt: Self.fixedDate
    )
    var seed = GitPlatformFeature.State()
    seed.snapshotsByProject[projectID] = cached
    let store = Self.makeStore(initialState: seed) { client in
      client.batchPullRequests = { _, _ in [:] }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }

    await store.send(.projectRefreshRequested(projectID, gitRoot: gitRoot, worktreeBranches: [pair])) {
      $0.lastFetchStartedAt[projectID] = Self.fixedDate
      $0.projectGitRoots[projectID] = gitRoot
      $0.projectWorktreePairs[projectID] = [pair]
      $0.projectByWorktree[wid] = projectID
      $0.inFlightFetchProjects = [projectID]
    }
    #expect(store.state.loading.isEmpty)
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, _, .success) = action else { return false }
      return pid == projectID
    } assert: {
      $0.inFlightFetchProjects = []
      $0.snapshotsByProject[projectID] = cached
    }
  }

  // MARK: - liveness poll

  /// A fetch unit whose id sorts by `index`, so tie-breaks in the scheduler order are
  /// deterministic. Its gitRoot names the repo the stubbed `remoteInfo` resolves to.
  private static func pollUnit(_ index: Int) -> GitPlatformFeature.FetchUnit {
    let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
    return GitPlatformFeature.FetchUnit(
      projectID: ProjectID(raw: uuid),
      gitRoot: URL(fileURLWithPath: "/repo/r\(index)"),
      pairs: [.init(worktreeID: WorktreeID(), branch: "b\(index)")])
  }

  /// Stubs the fetch chain so each call records the repo it fetched, optionally held
  /// open on `gate` to keep it in flight.
  private static func makePollStore(
    initialState: GitPlatformFeature.State = .init(),
    clock: TestClock<Duration>,
    date: DateGenerator = .constant(fixedDate),
    gate: Gate? = nil,
    calls: LockIsolated<[String]>
  ) -> TestStore<GitPlatformFeature.State, GitPlatformFeature.Action> {
    let store = makeStore(initialState: initialState, clock: clock, date: date) { client in
      client.batchPullRequests = { repository, _ in
        calls.withValue { $0.append(repository.pathSegments.last ?? "") }
        await gate?.wait()
        return [:]
      }
    } customizeGit: { git in
      git.remoteInfo = { root in
        RemoteInfo(host: "github.com", path: "w/\(root.lastPathComponent)")
      }
    }
    store.exhaustivity = .off
    return store
  }

  /// Seeds a polling store whose units all have a context to fetch with.
  private static func pollState(
    _ units: [GitPlatformFeature.FetchUnit],
    selected: Set<ProjectID>,
    lastStarted: [ProjectID: Date] = [:],
    isPolling: Bool = true
  ) -> GitPlatformFeature.State {
    var state = GitPlatformFeature.State()
    state.isPolling = isPolling
    state.pollUnits = Set(units.map(\.projectID))
    state.selectedUnits = selected
    state.lastFetchStartedAt = lastStarted
    for unit in units {
      state.projectGitRoots[unit.projectID] = unit.gitRoot
      state.projectWorktreePairs[unit.projectID] = unit.pairs
    }
    return state
  }

  @Test
  func focusGainedFetchesEveryUnitSelectedFirstUnderTheConcurrencyCap() async {
    let clock = TestClock()
    let gate = Gate()
    let calls = LockIsolated<[String]>([])
    let (a, b, c) = (Self.pollUnit(3), Self.pollUnit(1), Self.pollUnit(2))
    let store = Self.makePollStore(clock: clock, gate: gate, calls: calls)

    await store.send(.pollUnitsChanged([a, b, c], selected: [a.projectID]))
    #expect(store.state.inFlightFetchProjects.isEmpty)

    await store.send(.appActiveChanged(true))
    // The selected unit goes first; the next slot goes to the lowest id of the rest.
    #expect(store.state.inFlightFetchProjects == [a.projectID, b.projectID])
    #expect(store.state.pendingPollRefresh == [c.projectID])

    gate.open()
    // A finished fetch hands its slot to the queued unit without waiting for the timer.
    await store.receive(\.projectBatchLoaded)
    await store.receive(\.projectBatchLoaded)
    await store.receive(\.projectBatchLoaded)
    #expect(Set(calls.value) == ["r1", "r2", "r3"])
    #expect(calls.value.count == 3)
    #expect(store.state.pendingPollRefresh.isEmpty)

    await store.send(.appActiveChanged(false))
  }

  @Test
  func focusGainedSkipsUnitsFetchedWithinTheDebounce() async {
    let clock = TestClock()
    let calls = LockIsolated<[String]>([])
    let (recent, stale) = (Self.pollUnit(1), Self.pollUnit(2))
    let seed = Self.pollState(
      [recent, stale], selected: [],
      lastStarted: [
        recent.projectID: Self.fixedDate.addingTimeInterval(-10),
        stale.projectID: Self.fixedDate.addingTimeInterval(-31),
      ],
      isPolling: false)
    let store = Self.makePollStore(initialState: seed, clock: clock, calls: calls)

    await store.send(.appActiveChanged(true))
    #expect(store.state.inFlightFetchProjects == [stale.projectID])
    await store.receive(\.projectBatchLoaded)
    #expect(calls.value == ["r2"])

    await store.send(.appActiveChanged(false))
  }

  @Test
  func tickFetchesOnlyUnitsWhoseTierCadenceElapsed() async {
    let clock = TestClock()
    let calls = LockIsolated<[String]>([])
    let (selected, other) = (Self.pollUnit(1), Self.pollUnit(2))
    // Both cold. 61 s is past the selected cadence (60 s) but not the other's (300 s).
    let started = Self.fixedDate.addingTimeInterval(-61)
    let seed = Self.pollState(
      [selected, other], selected: [selected.projectID],
      lastStarted: [selected.projectID: started, other.projectID: started])
    let store = Self.makePollStore(initialState: seed, clock: clock, calls: calls)

    await store.send(.pollTick)
    #expect(store.state.inFlightFetchProjects == [selected.projectID])
    await store.receive(\.projectBatchLoaded)
    #expect(calls.value == ["r1"])

    await store.send(.appActiveChanged(false))
  }

  @Test
  func timerFiresWhenTheEarliestCadenceElapses() async {
    let clock = TestClock()
    let calls = LockIsolated<[String]>([])
    let base = Self.fixedDate
    let now = LockIsolated(base)
    let unit = Self.pollUnit(1)
    let seed = Self.pollState(
      [unit], selected: [unit.projectID], lastStarted: [unit.projectID: Self.fixedDate],
      isPolling: false)
    let store = Self.makePollStore(
      initialState: seed, clock: clock, date: DateGenerator { now.value }, calls: calls)

    // Fetched just now: no catch-up, the timer arms for the selected cold cadence.
    await store.send(.appActiveChanged(true))
    #expect(store.state.inFlightFetchProjects.isEmpty)

    now.setValue(base.addingTimeInterval(59))
    await clock.advance(by: .seconds(59))
    #expect(calls.value.isEmpty)

    now.setValue(base.addingTimeInterval(60))
    await clock.advance(by: .seconds(1))
    await store.receive(\.pollTick)
    await store.receive(\.projectBatchLoaded)
    #expect(calls.value == ["r1"])

    await store.send(.appActiveChanged(false))
  }

  @Test
  func pauseCancelsTheTimer() async {
    let clock = TestClock()
    let calls = LockIsolated<[String]>([])
    let unit = Self.pollUnit(1)
    let seed = Self.pollState(
      [unit], selected: [unit.projectID], lastStarted: [unit.projectID: Self.fixedDate],
      isPolling: false)
    let store = Self.makePollStore(initialState: seed, clock: clock, calls: calls)

    await store.send(.appActiveChanged(true))
    await store.send(.appActiveChanged(false))
    #expect(store.state.isPolling == false)
    await clock.advance(by: .seconds(600))
    #expect(calls.value.isEmpty)
  }

  @Test
  func refreshAllFetchesEveryUnitRegardlessOfCadence() async {
    let clock = TestClock()
    let calls = LockIsolated<[String]>([])
    let (a, b) = (Self.pollUnit(1), Self.pollUnit(2))
    let seed = Self.pollState(
      [a, b], selected: [a.projectID],
      lastStarted: [a.projectID: Self.fixedDate, b.projectID: Self.fixedDate])
    let store = Self.makePollStore(initialState: seed, clock: clock, calls: calls)

    await store.send(.refreshAllRequested)
    await store.receive(\.projectBatchLoaded)
    await store.receive(\.projectBatchLoaded)
    #expect(Set(calls.value) == ["r1", "r2"])

    await store.send(.appActiveChanged(false))
  }

  @Test
  func pollUnitsChangedMovesABadgeToTheNewBranch() async {
    let projectID = ProjectID()
    let moved = WorktreeID()
    let gone = WorktreeID()
    let kept = WorktreeID()
    let oldSnap = Self.stubSnapshot(number: 1, headRefName: "old")
    let newSnap = Self.stubSnapshot(number: 2, headRefName: "new")
    let keptSnap = Self.stubSnapshot(number: 3, headRefName: "kept")
    var seed = GitPlatformFeature.State()
    seed.snapshots = [moved: oldSnap, gone: oldSnap, kept: keptSnap]
    seed.snapshotsByProject[projectID] = BatchedPullRequests(
      repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
      byBranch: ["old": oldSnap, "new": newSnap, "kept": keptSnap],
      seenBranches: ["old", "new", "kept"], fetchedAt: Self.fixedDate)
    let store = Self.makeStore(initialState: seed)
    let pairs: [GitPlatformFeature.Action.WorktreeBranchPair] = [
      .init(worktreeID: moved, branch: "new"),
      .init(worktreeID: gone, branch: "no-pr"),
      .init(worktreeID: kept, branch: "kept"),
    ]
    let unit = GitPlatformFeature.FetchUnit(
      projectID: projectID, gitRoot: URL(fileURLWithPath: "/repo"), pairs: pairs)

    // Not polling: only the context and the badges change, no fetch starts.
    await store.send(.pollUnitsChanged([unit], selected: [])) {
      $0.pollUnits = [projectID]
      $0.projectGitRoots[projectID] = URL(fileURLWithPath: "/repo")
      $0.projectWorktreePairs[projectID] = pairs
      $0.projectByWorktree = [moved: projectID, gone: projectID, kept: projectID]
      // A worktree that switched branches must not keep the old branch's PR.
      $0.snapshots = [moved: newSnap, kept: keptSnap]
    }
  }

  // MARK: - fetch units added

  /// `codans project add` runs from any terminal, so the app is often not frontmost and the
  /// poll is paused. The new unit is still fetched at once, without a selection change or a
  /// poll tick, and joins the poll at the unselected cadence.
  @Test
  func anAddedUnitIsFetchedAtOnceWithoutSelectionOrTick() async {
    let clock = TestClock()
    let calls = LockIsolated<[String]>([])
    let (selected, added) = (Self.pollUnit(1), Self.pollUnit(2))
    let seed = Self.pollState(
      [selected], selected: [selected.projectID], lastStarted: [selected.projectID: Self.fixedDate],
      isPolling: false)
    let store = Self.makePollStore(initialState: seed, clock: clock, calls: calls)

    await store.send(.fetchUnitsAdded([added]))
    #expect(store.state.inFlightFetchProjects == [added.projectID])
    #expect(store.state.pollUnits == [selected.projectID, added.projectID])
    #expect(store.state.selectedUnits == [selected.projectID])
    #expect(store.state.projectByWorktree[added.pairs[0].worktreeID] == added.projectID)
    await store.receive(\.projectBatchLoaded)
    #expect(calls.value == ["r2"])
    #expect(store.state.pendingPollRefresh.isEmpty)
  }

  /// A repository added to a Workspace adds one unit; the Workspace's other units were
  /// fetched before and are not fetched again.
  @Test
  func aRepositoryAddedToAWorkspaceFetchesOnlyItsNewUnit() async {
    let clock = TestClock()
    let calls = LockIsolated<[String]>([])
    let (existing, added) = (Self.pollUnit(1), Self.pollUnit(2))
    let seed = Self.pollState(
      [existing], selected: [], lastStarted: [existing.projectID: Self.fixedDate], isPolling: false)
    let store = Self.makePollStore(initialState: seed, clock: clock, calls: calls)

    await store.send(.fetchUnitsAdded([existing, added]))
    #expect(store.state.inFlightFetchProjects == [added.projectID])
    await store.receive(\.projectBatchLoaded)
    #expect(calls.value == ["r2"])
  }

  @Test
  func addedUnitsShareThePollConcurrencyCap() async {
    let clock = TestClock()
    let gate = Gate()
    let calls = LockIsolated<[String]>([])
    let (a, b, c) = (Self.pollUnit(1), Self.pollUnit(2), Self.pollUnit(3))
    let store = Self.makePollStore(clock: clock, gate: gate, calls: calls)

    await store.send(.fetchUnitsAdded([a, b, c]))
    #expect(store.state.inFlightFetchProjects == [a.projectID, b.projectID])
    #expect(store.state.pendingPollRefresh == [c.projectID])

    gate.open()
    await store.receive(\.projectBatchLoaded)
    await store.receive(\.projectBatchLoaded)
    await store.receive(\.projectBatchLoaded)
    #expect(Set(calls.value) == ["r1", "r2", "r3"])
    #expect(store.state.pendingPollRefresh.isEmpty)
  }

  /// An added unit whose `origin` no Git Platform serves resolves once, like any other
  /// fetch, and the poll then skips it.
  @Test
  func anAddedUnitWithoutAGitPlatformResolvesOnceThenThePollSkipsIt() async {
    let clock = TestClock()
    let base = Self.fixedDate
    let now = LockIsolated(base)
    let resolutions = LockIsolated(0)
    let unit = Self.pollUnit(1)
    let store = Self.makeStore(clock: clock, date: DateGenerator { now.value }) { client in
      client.resolveRepository = { _, _ in
        resolutions.withValue { $0 += 1 }
        return nil
      }
      client.batchPullRequests = { _, _ in
        Issue.record("a unit without a Git Platform must not be read")
        return [:]
      }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "git.example.com", path: "w/r1") }
    }
    store.exhaustivity = .off

    await store.send(.fetchUnitsAdded([unit]))
    await store.receive(.gitPlatformUnresolved(unit.projectID, worktreeBranches: unit.pairs))
    #expect(store.state.unitsWithoutGitPlatform == [unit.projectID])
    #expect(resolutions.value == 1)

    await store.send(.appActiveChanged(true))
    now.setValue(base.addingTimeInterval(600))
    await clock.advance(by: .seconds(600))
    await store.send(.pollTick)
    #expect(store.state.inFlightFetchProjects.isEmpty)
    #expect(resolutions.value == 1)

    await store.send(.appActiveChanged(false))
  }

  @Test
  func remoteRefsChangeRefreshesTheUnitAndPollsItHot() async {
    let clock = TestClock()
    let calls = LockIsolated<[String]>([])
    let base = Self.fixedDate
    let now = LockIsolated(base)
    let (pushed, other) = (Self.pollUnit(1), Self.pollUnit(2))
    let seed = Self.pollState(
      [pushed, other], selected: [],
      lastStarted: [pushed.projectID: Self.fixedDate, other.projectID: Self.fixedDate])
    let store = Self.makePollStore(
      initialState: seed, clock: clock, date: DateGenerator { now.value }, calls: calls)

    await store.send(.remoteRefsChanged(pushed.projectID))
    #expect(
      store.state.hotUntil[pushed.projectID]
        == base.addingTimeInterval(GitPlatformFeature.remoteRefsHotWindow))
    // GitHub gets a moment to open the PR a `gh pr create` pushes for.
    await clock.advance(by: .seconds(2))
    await store.receive(\.delayedProjectRefreshFired)
    await store.receive(\.projectBatchLoaded)
    #expect(calls.value == ["r1"])

    // Within the window the unit polls on the hot cadence for an unselected
    // unit (30 s), while the cold one waits for its own (300 s).
    now.setValue(base.addingTimeInterval(30))
    await store.send(.pollTick)
    await store.receive(\.projectBatchLoaded)
    #expect(calls.value == ["r1", "r1"])

    await store.send(.appActiveChanged(false))
  }

  @Test
  func remoteRefsChangeForAnUnknownUnitIsIgnored() async {
    let store = Self.makeStore()
    await store.send(.remoteRefsChanged(ProjectID()))
  }

  @Test
  func pollTierIsHotWhenAnyCheckIsRunning() {
    let batched = BatchedPullRequests(
      repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
      byBranch: ["b": Self.snapshot(state: .open, checkStatus: .inProgress, merge: .clean)],
      seenBranches: ["b"], fetchedAt: Self.fixedDate
    )
    #expect(GitPlatformFeature.pollTier(for: batched) == .hot)
  }

  @Test
  func pollTierIsHotWhenMergeStateUnknown() {
    let batched = BatchedPullRequests(
      repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
      byBranch: ["b": Self.snapshot(state: .open, checkStatus: .completed, merge: .unknown)],
      seenBranches: ["b"], fetchedAt: Self.fixedDate
    )
    #expect(GitPlatformFeature.pollTier(for: batched) == .hot)
  }

  @Test
  func pollTierIsWarmWhenOpenPullRequestsSettled() {
    let batched = BatchedPullRequests(
      repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
      byBranch: ["b": Self.snapshot(state: .open, checkStatus: .completed, merge: .clean)],
      seenBranches: ["b"], fetchedAt: Self.fixedDate
    )
    #expect(GitPlatformFeature.pollTier(for: batched) == .warm)
  }

  @Test
  func pollTierIsColdWithoutAnOpenPullRequest() {
    let merged = BatchedPullRequests(
      repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
      byBranch: ["b": Self.snapshot(state: .merged, checkStatus: .inProgress, merge: .unknown)],
      seenBranches: ["b"], fetchedAt: Self.fixedDate
    )
    #expect(GitPlatformFeature.pollTier(for: merged) == .cold)
    #expect(GitPlatformFeature.pollTier(for: nil) == .cold)
  }

  @Test
  func selectedUnitsPollFasterInEveryTier() {
    for tier in [GitPlatformFeature.PollTier.hot, .warm, .cold] {
      #expect(
        GitPlatformFeature.pollInterval(tier, selected: true)
          < GitPlatformFeature.pollInterval(tier, selected: false))
    }
  }

  @Test
  func postMutationSchedulesDelayedProjectRefresh() async {
    let clock = TestClock()
    let projectID = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/r")
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")
    let snap = Self.stubSnapshot(number: 99, state: .open, headRefName: "feature/x")
    var seed = GitPlatformFeature.State()
    seed.snapshots[wid] = snap
    seed.projectByWorktree[wid] = projectID
    seed.projectGitRoots[projectID] = gitRoot
    seed.projectWorktreePairs[projectID] = [pair]
    let store = Self.makeStore(initialState: seed, clock: clock) { client in
      client.merge = { _, _, _ in }
      client.batchPullRequests = { _, _ in ["feature/x": snap] }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }
    await store.send(.mergeRequested(wid, Self.reference(99), strategy: .squash, headSHA: "abc123")) {
      $0.mutating.insert(wid)
    }
    await store.receive(.mergeCompleted(wid, prNumber: 99, .success(.init()))) {
      $0.mutating.remove(wid)
    }
    await store.receive(.delegate(.pullRequestMerged(wid, snapshot: snap)))
    // Delayed 2 s so GitHub settles the write before we read it back.
    await clock.advance(by: .seconds(2))
    await store.receive(.delayedProjectRefreshFired(projectID)) {
      $0.lastFetchStartedAt[projectID] = Self.fixedDate
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
        repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
        byBranch: ["feature/x": snap], seenBranches: ["feature/x"], fetchedAt: Self.fixedDate
      )
      $0.snapshots[wid] = snap
      $0.snapshotLoadedAt[wid] = Self.fixedDate
    }
  }

  @Test
  func aDelayedRefreshDoesNotReviveAProjectRemovedWhileItWaited() async {
    let clock = TestClock()
    let projectID = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/r")
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "feature/x")
    let snap = Self.stubSnapshot(number: 99, state: .open, headRefName: "feature/x")
    var seed = GitPlatformFeature.State()
    seed.snapshots[wid] = snap
    seed.projectByWorktree[wid] = projectID
    seed.projectGitRoots[projectID] = gitRoot
    seed.projectWorktreePairs[projectID] = [pair]
    let store = Self.makeStore(initialState: seed, clock: clock) { client in
      client.merge = { _, _, _ in }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }
    await store.send(.mergeRequested(wid, Self.reference(99), strategy: .squash, headSHA: "abc123")) {
      $0.mutating.insert(wid)
    }
    await store.receive(.mergeCompleted(wid, prNumber: 99, .success(.init()))) {
      $0.mutating.remove(wid)
    }
    await store.receive(.delegate(.pullRequestMerged(wid, snapshot: snap)))

    // The Project leaves the catalog inside the two-second window.
    await store.send(.pruneToCatalog(projectIDs: [], worktreeIDs: [])) {
      $0.projectByWorktree = [:]
      $0.projectGitRoots = [:]
      $0.projectWorktreePairs = [:]
      $0.snapshots = [:]
      $0.snapshotLoadedAt = [:]
    }

    // Firing resolves membership from state, so there is nothing to refetch.
    // Replaying the pairs captured when the timer was armed would put the
    // Project back into `projectGitRoots` and `loading`.
    await clock.advance(by: .seconds(2))
    await store.receive(.delayedProjectRefreshFired(projectID))
  }

  @Test
  func aDelayedRefreshSkipsAWorktreeRemovedWhileItWaited() async {
    let clock = TestClock()
    let projectID = ProjectID()
    let keptWID = WorktreeID()
    let goneWID = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/tmp/r")
    let kept = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: keptWID, branch: "main")
    let gone = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: goneWID, branch: "old")
    let snap = Self.stubSnapshot(number: 99, state: .open, headRefName: "main")
    var seed = GitPlatformFeature.State()
    seed.snapshots[goneWID] = snap
    seed.projectByWorktree = [keptWID: projectID, goneWID: projectID]
    seed.projectGitRoots[projectID] = gitRoot
    seed.projectWorktreePairs[projectID] = [kept, gone]
    let store = Self.makeStore(initialState: seed, clock: clock) { client in
      client.merge = { _, _, _ in }
      client.batchPullRequests = { _, _ in ["main": snap] }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }
    await store.send(
      .mergeRequested(goneWID, Self.reference(99), strategy: .squash, headSHA: "abc123")
    ) {
      $0.mutating.insert(goneWID)
    }
    await store.receive(.mergeCompleted(goneWID, prNumber: 99, .success(.init()))) {
      $0.mutating.remove(goneWID)
    }
    await store.receive(.delegate(.pullRequestMerged(goneWID, snapshot: snap)))

    // Only the merged Worktree is removed; its Project survives.
    await store.send(.pruneToCatalog(projectIDs: [projectID], worktreeIDs: [keptWID])) {
      $0.projectByWorktree = [keptWID: projectID]
      $0.projectWorktreePairs[projectID] = [kept]
      $0.snapshots = [:]
    }

    await clock.advance(by: .seconds(2))
    await store.receive(.delayedProjectRefreshFired(projectID)) {
      $0.lastFetchStartedAt[projectID] = Self.fixedDate
      $0.inFlightFetchProjects.insert(projectID)
      $0.loading.insert(keptWID)
    }
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, _, .success) = action else { return false }
      return pid == projectID
    } assert: {
      $0.inFlightFetchProjects.remove(projectID)
      $0.loading.remove(keptWID)
      $0.lastErrorByProject[projectID] = nil
      $0.snapshotsByProject[projectID] = BatchedPullRequests(
        repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
        byBranch: ["main": snap], seenBranches: ["main"], fetchedAt: Self.fixedDate
      )
      $0.snapshots[keptWID] = snap
      $0.snapshotLoadedAt[keptWID] = Self.fixedDate
      $0.lastError[keptWID] = nil
    }
    #expect(store.state.projectByWorktree[goneWID] == nil)
    #expect(store.state.snapshots[goneWID] == nil)
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
        repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
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
  func pruneToCatalogDropsDeadKeysAndTheirPollUnits() async {
    let live = ProjectID()
    let dead = ProjectID()
    let liveWID = WorktreeID()
    let deadWID = WorktreeID()
    let snap = Self.snapshot(state: .open, checkStatus: .completed, merge: .clean)
    var seed = GitPlatformFeature.State()
    seed.snapshots = [liveWID: snap, deadWID: snap]
    seed.snapshotLoadedAt = [liveWID: Self.fixedDate, deadWID: Self.fixedDate]
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
    seed.pollUnits = [live, dead]
    seed.selectedUnits = [dead]
    seed.pendingPollRefresh = [dead]
    seed.lastFetchStartedAt = [live: Self.fixedDate, dead: Self.fixedDate]
    let store = Self.makeStore(initialState: seed)

    await store.send(
      .pruneToCatalog(projectIDs: [live], worktreeIDs: [liveWID])
    ) {
      $0.snapshots = [liveWID: snap]
      $0.snapshotLoadedAt = [liveWID: Self.fixedDate]
      $0.projectByWorktree = [liveWID: live]
      $0.mutating = []
      $0.projectGitRoots = [live: URL(fileURLWithPath: "/repo")]
      $0.projectWorktreePairs = [live: [.init(worktreeID: liveWID, branch: "main")]]
      $0.inFlightFetchProjects = []
      $0.queuedRefreshByProject = []
      // A poll left covering a removed Project keeps shelling out
      // `gh api graphql` against a repository the user unregistered, and each
      // success writes it straight back into the on-disk cache.
      $0.pollUnits = [live]
      $0.selectedUnits = []
      $0.pendingPollRefresh = []
      $0.lastFetchStartedAt = [live: Self.fixedDate]
    }
  }

  @Test
  func pruneCancelsAnInFlightFetchForARemovedProject() async {
    let dead = ProjectID()
    let wid = WorktreeID()
    let gitRoot = URL(fileURLWithPath: "/gone")
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "main")
    let gate = Gate()
    let snap = Self.stubSnapshot(number: 1, headRefName: "main")
    let store = Self.makeStore { client in
      client.batchPullRequests = { _, _ in
        await gate.wait()
        return ["main": snap]
      }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }

    await store.send(.projectActivated(dead, gitRoot: gitRoot, worktreeBranches: [pair])) {
      $0.lastFetchStartedAt[dead] = Self.fixedDate
      $0.projectGitRoots[dead] = gitRoot
      $0.projectWorktreePairs[dead] = [pair]
      $0.projectByWorktree[wid] = dead
      $0.loading.insert(wid)
      $0.inFlightFetchProjects.insert(dead)
    }

    // The Project leaves the catalog while `gh api graphql` is still running.
    await store.send(.pruneToCatalog(projectIDs: [], worktreeIDs: [])) {
      $0.lastFetchStartedAt = [:]
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
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "main")
    var seed = GitPlatformFeature.State()
    seed.projectGitRoots = [dead: URL(fileURLWithPath: "/gone")]
    seed.projectWorktreePairs = [dead: [pair]]
    seed.projectByWorktree = [wid: dead]
    seed.inFlightFetchProjects = [dead]
    seed.loading = [wid]
    let store = Self.makeStore(initialState: seed)

    await store.send(.pruneToCatalog(projectIDs: [], worktreeIDs: [])) {
      $0.lastFetchStartedAt = [:]
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
      repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
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
    let pair = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: wid, branch: "main")
    var seed = GitPlatformFeature.State()
    seed.projectGitRoots = [dead: URL(fileURLWithPath: "/gone")]
    seed.inFlightFetchProjects = [dead]
    seed.loading = [wid]
    let store = Self.makeStore(initialState: seed)

    await store.send(.pruneToCatalog(projectIDs: [], worktreeIDs: [])) {
      $0.lastFetchStartedAt = [:]
      $0.projectGitRoots = [:]
      $0.inFlightFetchProjects = []
      $0.loading = []
    }
    await store.send(
      .projectBatchLoaded(dead, worktreeBranches: [pair], .failure(GitPlatformError.network("DNS")))
    )
  }

  @Test
  func aLateSuccessSkipsWorktreesRemovedWhileTheProjectSurvived() async {
    let live = ProjectID()
    let keptWID = WorktreeID()
    let goneWID = WorktreeID()
    let kept = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: keptWID, branch: "main")
    let gone = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: goneWID, branch: "old")
    var seed = GitPlatformFeature.State()
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
      repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
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
    let kept = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: keptWID, branch: "main")
    let gone = GitPlatformFeature.Action.WorktreeBranchPair(worktreeID: goneWID, branch: "old")
    let gitRoot = URL(fileURLWithPath: "/repo")
    let keptSnap = Self.stubSnapshot(number: 1, headRefName: "main")
    let goneSnap = Self.stubSnapshot(number: 2, headRefName: "old")
    let gate = Gate()
    let store = Self.makeStore { client in
      client.batchPullRequests = { _, branches in
        await gate.wait()
        var out: [String: PullRequestSnapshot] = [:]
        if branches.contains("main") { out["main"] = keptSnap }
        if branches.contains("old") { out["old"] = goneSnap }
        return out
      }
    } customizeGit: { git in
      git.remoteInfo = { _ in RemoteInfo(host: "github.com", path: "w/r") }
    }

    // A fetch for both Worktrees goes in flight.
    await store.send(
      .projectActivated(project, gitRoot: gitRoot, worktreeBranches: [kept, gone])
    ) {
      $0.lastFetchStartedAt[project] = Self.fixedDate
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
        repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
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
      // A batch is cached by now, so the drained refresh shows no spinner.
      $0.inFlightFetchProjects = [project]
    }
    await store.receive { action in
      guard case .projectBatchLoaded(let pid, _, .success) = action else { return false }
      return pid == project
    } assert: {
      $0.inFlightFetchProjects = []
      $0.loading = []
      $0.snapshotsByProject[project] = BatchedPullRequests(
        repository: GitPlatformRepository(kind: .github, host: "github.com", path: "w/r"),
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
    var seed = GitPlatformFeature.State()
    seed.pollUnits = [live]
    seed.projectGitRoots = [live: URL(fileURLWithPath: "/repo")]
    let store = Self.makeStore(initialState: seed)

    await store.send(.pruneToCatalog(projectIDs: [live], worktreeIDs: []))
  }

  /// Cadence-predicate fixture: an open/settled/in-flight snapshot in one line.
  private static func snapshot(
    state: PullRequestState,
    checkStatus: CheckStatus,
    merge: PullRequestMergeState.Status
  ) -> PullRequestSnapshot {
    PullRequestSnapshot(
      number: 1, title: "t", state: state, isDraft: false, headRefName: "b",
      author: "a", additions: 0, deletions: 0, commitCount: 1,
      url: URL(string: "https://github.com/w/r/pull/1")!, updatedAt: fixedDate,
      checkRollup: [
        CheckResult(
          name: "build", status: checkStatus,
          conclusion: checkStatus == .completed ? .success : nil
        )
      ],
      mergeState: PullRequestMergeState(status: merge)
    )
  }
}
