import ComposableArchitecture
import Foundation
import CodansCore
import os.log

/// TCA reducer owning the GitHub integration's per-app state — availability probe result,
/// per-Worktree PR snapshots (with check + workflow-run detail), popover presentation bit,
/// and per-Worktree last-error for the inline banner.
///
/// State is **memory-only** — nothing is persisted. On relaunch, everything reloads from
/// `gh` on first-view.
///
/// Mutations flow through explicit Requested → Completed action pairs (merge /
/// close / markReady / rerunFailedJobs). The Completed branch schedules a delayed
/// project-level refresh to pick up the new server state without hammering gh.
@Reducer
struct GitHubFeature {
  @ObservableState
  struct State: Equatable {
    var availability: GitHubAvailability = .unknown
    var availabilityProbedAt: Date?

    var snapshots: [WorktreeID: PullRequestSnapshot] = [:]
    var snapshotLoadedAt: [WorktreeID: Date] = [:]

    /// Latest workflow run keyed by PR number. Seeds the "Rerun failed jobs" action.
    /// Remains a popover-time single-call lookup — the batched query does not yet
    /// carry workflow-run IDs.
    var latestWorkflowRuns: [Int: WorkflowRun] = [:]

    /// Worktrees whose owning Project has a batched fetch in flight (or
    /// queued behind one). The badge and popover render a spinner from this.
    var loading: Set<WorktreeID> = []

    /// Mutation operations in flight per Worktree. Views observe this to disable the
    /// matching popover button so repeated clicks can't fire multiple `gh` subprocesses.
    var mutating: Set<WorktreeID> = []

    /// Worktree paths observed via `presentPopover` and the mutation requests. Stashed so
    /// popover-time effects (the latest workflow-run fetch) can resolve a path from a
    /// WorktreeID alone without the completed action having to carry it.
    var worktreePaths: [WorktreeID: URL] = [:]

    /// Which Worktree's popover is visible. `nil` ⇒ no popover.
    var popoverTarget: WorktreeID?

    /// Per-Worktree last-seen error, cleared on successful refresh.
    var lastError: [WorktreeID: GitHubError] = [:]

    // MARK: - v2 project-batched fetch

    /// Cached batched result per Project. Keyed by ProjectID because the batched
    /// GraphQL query targets a single repository. The whole map is rebuilt lazily on
    /// Project activation / invalidation events.
    var snapshotsByProject: [ProjectID: BatchedPullRequests] = [:]

    /// Set of Projects with an active `batchPullRequests` subprocess in flight. Used by
    /// the re-entrancy guard: a second `projectRefreshRequested` for a Project already
    /// in this set is queued, not dispatched.
    var inFlightFetchProjects: Set<ProjectID> = []

    /// Projects that requested a refresh while a prior fetch was in flight. Drained
    /// into a new fetch when the in-flight fetch completes.
    var queuedRefreshByProject: Set<ProjectID> = []

    /// Per-Project last-seen error from the batched fetch. Cleared on next success.
    /// Displayed in the sidebar's Settings → GitHub banner, not per-row.
    var lastErrorByProject: [ProjectID: GitHubError] = [:]

    /// Last-known gitRoot per Project. Stashed so the queued-refresh drain + the
    /// delayed post-mutation refresh can re-issue a fetch without the caller re-passing
    /// the gitRoot. Not yet cleared when the Project is removed from the catalog.
    var projectGitRoots: [ProjectID: URL] = [:]

    // MARK: - active-Project liveness poll

    /// Project the foreground liveness poll currently refreshes; `nil` ⇒ paused (app not
    /// active, or no active Project). Set by `pollTargetChanged`; the loop re-issues a
    /// forced `projectRefreshRequested` for this Project on an adaptive cadence while the
    /// app is foreground.
    var pollTarget: ProjectID?

    /// Last-known branch pairs per Project, so a poll tick — or a post-mutation /
    /// manual-retry refresh — can re-issue a fetch without the caller re-supplying them.
    /// Written everywhere `projectGitRoots[P]` is written (inside `enqueueProjectFetch`)
    /// and on `pollTargetChanged`.
    var projectWorktreePairs: [ProjectID: [Action.WorktreeBranchPair]] = [:]

    /// Worktree → owning Project. Lets `postMutationRefresh` + the badge/popover retry
    /// resolve a project-level batched fetch from a `WorktreeID` alone.
    var projectByWorktree: [WorktreeID: ProjectID] = [:]

    /// PR-number ↔ Worktree map derived from `snapshots`. Keeps lookup O(1) for action
    /// completion handlers that only know the PR number.
    func worktree(for prNumber: Int) -> WorktreeID? {
      snapshots.first(where: { $0.value.number == prNumber })?.key
    }
  }

  /// Monotonic stamp handed to every on-disk cache write so a save that
  /// started earlier cannot land after a newer one. See
  /// `GitHubSnapshotCache.save(_:sequence:)`.
  ///
  /// Lives outside `State` because it orders side effects, not UI: bumping
  /// it must not read as a state change to `TestStore` assertions.
  private static let cacheWriteSequence = CacheWriteSequence()

  final class CacheWriteSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UInt64 {
      lock.lock()
      defer { lock.unlock() }
      value += 1
      return value
    }
  }

  enum Action: Equatable {
    case onAppear
    /// Hydrates the v2 project-batched state from the on-disk snapshot cache so the
    /// sidebar paints PR badges immediately on launch instead of flashing empty →
    /// populated when the first GraphQL fetch returns. Fired once at app bootstrap.
    /// `branchPairsByProject` is passed so the reducer can project cached
    /// `byBranch` snapshots into the per-Worktree `state.snapshots` dict that
    /// views read — caller (RootFeature) walks the catalog once at bootstrap to
    /// build the mapping.
    case seedFromCache(
      cached: [ProjectID: BatchedPullRequests],
      branchPairsByProject: [ProjectID: [WorktreeBranchPair]],
      liveProjectIDs: Set<ProjectID>
    )
    case refreshAvailabilityRequested
    case availabilityProbed(GitHubAvailability, probedAt: Date)

    case workflowRunLoaded(prNumber: Int, TaskResult<WorkflowRun?>)

    case presentPopover(WorktreeID, worktreePath: URL)
    case dismissPopover

    case mergeRequested(WorktreeID, prNumber: Int, strategy: MergeStrategy, worktreePath: URL)
    case mergeCompleted(WorktreeID, prNumber: Int, TaskResult<VoidSuccess>)

    case closeRequested(WorktreeID, prNumber: Int, worktreePath: URL)
    case closeCompleted(WorktreeID, TaskResult<VoidSuccess>)

    case markReadyRequested(WorktreeID, prNumber: Int, worktreePath: URL)
    case markReadyCompleted(WorktreeID, TaskResult<VoidSuccess>)

    case rerunFailedJobsRequested(WorktreeID, runID: Int64, worktreePath: URL)
    case rerunFailedJobsCompleted(WorktreeID, TaskResult<VoidSuccess>)

    // MARK: - v2 project-batched fetch

    /// Project gained focus or was freshly activated. If no cached snapshot exists (or
    /// the cached branch set does not match the current Worktree list), dispatch a full
    /// refresh. Payload carries the data the batched fetcher needs so the reducer does
    /// not read `HierarchyManager` synchronously inside an effect.
    case projectActivated(
      ProjectID,
      gitRoot: URL,
      worktreeBranches: [WorktreeBranchPair]
    )

    /// Force a fresh `gh api graphql` for the Project, respecting the in-flight + queued
    /// re-entrancy model. Used by manual refresh + post-write delayed refresh.
    case projectRefreshRequested(
      ProjectID,
      gitRoot: URL,
      worktreeBranches: [WorktreeBranchPair]
    )

    /// Result of a single `batchPullRequests` call. On success, the reducer stores the
    /// batched result under the Project and projects each branch's snapshot into the
    /// per-Worktree `state.snapshots` dict so v1 consumers see the refreshed data.
    case projectBatchLoaded(
      ProjectID,
      worktreeBranches: [WorktreeBranchPair],
      TaskResult<BatchedPullRequests>
    )


    // MARK: - active-Project liveness poll

    /// Retarget or pause the foreground liveness poll. A non-nil ProjectID arms the loop
    /// for that Project; `nil` pauses it (app resigned active, or no active Project).
    /// Retargeting does not fetch immediately — `projectActivated` / focus-gained already
    /// issue the immediate refresh; the poll only maintains freshness afterward.
    case pollTargetChanged(
      ProjectID?,
      gitRoot: URL?,
      worktreeBranches: [WorktreeBranchPair]
    )

    /// One beat of the liveness poll. Re-issues a forced fetch for the target Project and
    /// re-arms the next tick at the current adaptive cadence.
    case pollTick(ProjectID)

    /// Project-level refresh keyed by a single Worktree. Resolves the owning Project from
    /// `projectByWorktree` and runs the batched fetch. Backs the badge / popover
    /// error-state retry so a retry repaints the whole repo with full check rollups
    /// instead of the empty-checks v1 single-branch result.
    case worktreeRefreshRequested(WorktreeID)

    /// Drop every entry keyed by an ID the catalog no longer contains, and
    /// pause the poll when its target is among them. Sent by RootFeature on
    /// each structural hierarchy mutation. Nothing else in this feature ever
    /// removes a key: the maps are written by fetches and read by views that
    /// are already keyed to live rows, so without this they only grow, and
    /// `snapshotsByProject` carries the growth to disk.
    case pruneToCatalog(projectIDs: Set<ProjectID>, worktreeIDs: Set<WorktreeID>)

    /// The post-mutation timer elapsed. Carries only the Project id: the
    /// gitRoot and pairs are resolved from state when it fires, never
    /// captured when it was armed. A removal during the two-second wait
    /// would otherwise be undone by the stale membership it replayed.
    case delayedProjectRefreshFired(ProjectID)

    case delegate(Delegate)

    enum Delegate: Equatable {
      /// A merge completed successfully; the parent decides what to do with the Worktree
      /// (archive / delete / ask, per `MergedWorktreeAction`).
      case pullRequestMerged(WorktreeID, snapshot: PullRequestSnapshot)
      /// Palette's "Open Settings" entry — parent presents the Settings window at the
      /// GitHub section.
      case showSettingsGitHub
      /// Open a URL on GitHub in the default browser.
      case openURL(URL)
    }

    /// TaskResult<Void> isn't Equatable because Void isn't. Adopting a trivial sentinel
    /// lets the reducer's Action enum stay Equatable for TestStore. `nonisolated` so the
    /// zero-arg init stays callable from the `@Sendable` effect closures.
    nonisolated struct VoidSuccess: Equatable, Sendable {
      nonisolated init() {}
    }

    /// `(worktreeID, branch)` pair carried by the v2 project-batched actions. Passed
    /// into the reducer so it does not need to read `HierarchyManager` from inside an
    /// effect (which would require bridging `@MainActor` and the `@Sendable` effect
    /// boundary). The dispatcher — `RootFeature` observing `selectionChanges` —
    /// constructs the list from the current catalog once per dispatch.
    nonisolated struct WorktreeBranchPair: Equatable, Sendable, Hashable {
      let worktreeID: WorktreeID
      let branch: String
      init(worktreeID: WorktreeID, branch: String) {
        self.worktreeID = worktreeID
        self.branch = branch
      }
    }
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case availabilityRefresh
    case workflowRun(prNumber: Int)
    /// One-cancellation-slot for all mutations on a Worktree so a second click while an
    /// operation is in flight cancels the prior run rather than racing it.
    case mutation(WorktreeID)
    /// Per-Project batched fetch. Re-dispatching `projectRefreshRequested`
    /// for an in-flight Project cancels the prior fetch and replaces it.
    case projectFetch(ProjectID)
    /// Delayed post-mutation refresh — merge / close / markReady / rerun all
    /// schedule this 2 s after a successful write.
    case delayedProjectRefresh(ProjectID)
    /// `gh` availability recovery heartbeat — retries every 15 s after an outage.
    case availabilityRecovery
    /// Single re-arm slot for the active-Project liveness poll. Retargeting or
    /// pausing cancels the prior loop so at most one timer is ever live.
    case poll
  }

  /// Availability result is treated as fresh for 30 s; subsequent `onAppear` / visibility
  /// dispatches within the window skip the probe.
  static let availabilityFreshness: TimeInterval = 30

  // MARK: - active-Project liveness poll cadence

  /// Fast cadence — used while the target Project has at least one open PR with CI in
  /// flight or an unsettled merge state. Keeps the check overlay near-live.
  static let pollCadenceActive: Duration = .seconds(15)

  /// Slow cadence — used when everything is settled (or there is no open PR). Still runs
  /// while foreground so a remote merge / close / new PR surfaces within ~60 s.
  static let pollCadenceIdle: Duration = .seconds(60)

  @Dependency(GitHubClient.self) var gitHub
  /// Resolves `(host, owner, repo)` for batched fetches via `git remote get-url origin`.
  @Dependency(GitServiceClient.self) var gitServiceClient
  /// Persists the project-batched PR cache across launches so the sidebar paints
  /// immediately instead of flashing empty → populated as GraphQL fetches return.
  @Dependency(GitHubSnapshotCacheClient.self) var gitHubSnapshotCache
  @Dependency(\.date.now) var now
  /// Drives the liveness-poll re-arm timer + the post-mutation refresh delay. TestStore
  /// overrides this with a controllable clock.
  @Dependency(\.continuousClock) var clock

  /// Back-compat alias so existing `gitHubClient` usages compile unchanged. The
  /// reducer body was written with `gitHub`; the M4 additions use `gitHubClient` for
  /// clarity inside the new fetch effect builder.
  private var gitHubClient: GitHubClient { gitHub }

  nonisolated static let logger = Logger(subsystem: "com.gumpw.codans.github", category: "feature")

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {

      // MARK: - availability

      case .onAppear:
        if let probedAt = state.availabilityProbedAt,
          now.timeIntervalSince(probedAt) < Self.availabilityFreshness,
          case .available = state.availability
        {
          return .none
        }
        return probeAvailabilityEffect()

      case .seedFromCache(let cached, let branchPairsByProject, let liveProjectIDs):
        // Hydrate reducer state from disk. Two writes:
        //   1. `state.snapshotsByProject` — drives the `projectActivated`
        //      cache-hit check so we don't immediately over-fetch on bootstrap.
        //   2. `state.snapshots[worktreeID]` — what views read. Projected from
        //      each cached `byBranch` entry via the caller-supplied
        //      `branchPairsByProject` mapping.
        //
        // Filter to live Projects first. The cache is written back whole on
        // every successful fetch, so a Project the user removed would be
        // merged in here, re-persisted, and merged in again next launch —
        // the file grew without bound and kept PR titles and branch names
        // for repositories that were unregistered months earlier.
        let live = cached.filter { liveProjectIDs.contains($0.key) }
        if live.count != cached.count {
          Self.logger.info(
            "seed dropped \(cached.count - live.count, privacy: .public) cached project(s) absent from the catalog"
          )
        }
        state.snapshotsByProject.merge(live) { _, new in new }
        for (projectID, pairs) in branchPairsByProject {
          guard let batched = live[projectID] else { continue }
          for pair in pairs {
            if let snap = batched.byBranch[pair.branch] {
              state.snapshots[pair.worktreeID] = snap
              state.snapshotLoadedAt[pair.worktreeID] = batched.fetchedAt
            }
          }
        }
        return .none

      case .refreshAvailabilityRequested:
        state.availabilityProbedAt = nil  // bypass cache
        return probeAvailabilityEffect()

      case .availabilityProbed(let result, let probedAt):
        state.availability = result
        state.availabilityProbedAt = probedAt
        return .none

      // MARK: - workflow run loading

      case .workflowRunLoaded(let prNumber, .success(let run)):
        if let run {
          state.latestWorkflowRuns[prNumber] = run
        }
        return .none

      case .workflowRunLoaded:
        return .none  // swallow error — rerun button just stays disabled

      // MARK: - popover

      case .presentPopover(let worktreeID, let worktreePath):
        state.popoverTarget = worktreeID
        state.worktreePaths[worktreeID] = worktreePath
        // Checks travel on the snapshot now — the only thing popover-open
        // still needs to fetch is the latest workflow run, which seeds the
        // "Rerun failed jobs" button with a runID.
        guard let snapshot = state.snapshots[worktreeID] else { return .none }
        return workflowRunFetchEffect(
          prNumber: snapshot.number, branch: snapshot.headRefName, worktreePath: worktreePath
        )

      case .dismissPopover:
        state.popoverTarget = nil
        return .none

      // MARK: - merge

      case .mergeRequested(let worktreeID, let prNumber, let strategy, let worktreePath):
        if state.mutating.contains(worktreeID) { return .none }  // already running
        state.mutating.insert(worktreeID)
        state.worktreePaths[worktreeID] = worktreePath
        return .run { send in
          let result = await TaskResult<Action.VoidSuccess> {
            try await gitHub.merge(prNumber, strategy, worktreePath)
            return Action.VoidSuccess()
          }
          await send(.mergeCompleted(worktreeID, prNumber: prNumber, result))
        }
        .cancellable(id: CancelID.mutation(worktreeID), cancelInFlight: true)

      case .mergeCompleted(let worktreeID, _, .success):
        state.mutating.remove(worktreeID)
        // Delegate pullRequestMerged so RootFeature can trigger the post-merge action,
        // then kick off a refresh so the badge flips to merged on its own.
        let refresh = postMutationRefresh(worktreeID: worktreeID, state: &state)
        if let snapshot = state.snapshots[worktreeID] {
          return .merge(.send(.delegate(.pullRequestMerged(worktreeID, snapshot: snapshot))), refresh)
        }
        return refresh

      case .mergeCompleted(let worktreeID, _, .failure(let error)):
        state.mutating.remove(worktreeID)
        state.lastError[worktreeID] = (error as? GitHubError) ?? .other(String(describing: error))
        return .none

      // MARK: - close

      case .closeRequested(let worktreeID, let prNumber, let worktreePath):
        if state.mutating.contains(worktreeID) { return .none }
        state.mutating.insert(worktreeID)
        state.worktreePaths[worktreeID] = worktreePath
        return .run { send in
          let result = await TaskResult<Action.VoidSuccess> {
            try await gitHub.close(prNumber, worktreePath)
            return Action.VoidSuccess()
          }
          await send(.closeCompleted(worktreeID, result))
        }
        .cancellable(id: CancelID.mutation(worktreeID), cancelInFlight: true)

      case .closeCompleted(let worktreeID, .failure(let error)):
        state.mutating.remove(worktreeID)
        state.lastError[worktreeID] = (error as? GitHubError) ?? .other(String(describing: error))
        return .none

      case .closeCompleted(let worktreeID, _):
        state.mutating.remove(worktreeID)
        return postMutationRefresh(worktreeID: worktreeID, state: &state)

      // MARK: - markReady

      case .markReadyRequested(let worktreeID, let prNumber, let worktreePath):
        if state.mutating.contains(worktreeID) { return .none }
        state.mutating.insert(worktreeID)
        state.worktreePaths[worktreeID] = worktreePath
        return .run { send in
          let result = await TaskResult<Action.VoidSuccess> {
            try await gitHub.markReady(prNumber, worktreePath)
            return Action.VoidSuccess()
          }
          await send(.markReadyCompleted(worktreeID, result))
        }
        .cancellable(id: CancelID.mutation(worktreeID), cancelInFlight: true)

      case .markReadyCompleted(let worktreeID, .failure(let error)):
        state.mutating.remove(worktreeID)
        state.lastError[worktreeID] = (error as? GitHubError) ?? .other(String(describing: error))
        return .none

      case .markReadyCompleted(let worktreeID, _):
        state.mutating.remove(worktreeID)
        return postMutationRefresh(worktreeID: worktreeID, state: &state)

      // MARK: - rerunFailedJobs

      case .rerunFailedJobsRequested(let worktreeID, let runID, let worktreePath):
        if state.mutating.contains(worktreeID) { return .none }
        state.mutating.insert(worktreeID)
        state.worktreePaths[worktreeID] = worktreePath
        return .run { send in
          let result = await TaskResult<Action.VoidSuccess> {
            try await gitHub.rerunFailedJobs(runID, worktreePath)
            return Action.VoidSuccess()
          }
          await send(.rerunFailedJobsCompleted(worktreeID, result))
        }
        .cancellable(id: CancelID.mutation(worktreeID), cancelInFlight: true)

      case .rerunFailedJobsCompleted(let worktreeID, .failure(let error)):
        state.mutating.remove(worktreeID)
        state.lastError[worktreeID] = (error as? GitHubError) ?? .other(String(describing: error))
        return .none

      case .rerunFailedJobsCompleted(let worktreeID, _):
        state.mutating.remove(worktreeID)
        return postMutationRefresh(worktreeID: worktreeID, state: &state)

      // MARK: - v2 project-batched fetch

      case .projectActivated(let projectID, let gitRoot, let pairs):
        Self.logger.info(
          "projectActivated project=\(projectID.raw.uuidString, privacy: .public) branches=\(pairs.count, privacy: .public) gitRoot=\(gitRoot.path, privacy: .private(mask: .hash))"
        )
        if Self.isCacheFreshAndComplete(
          cached: state.snapshotsByProject[projectID], current: pairs, now: now
        ) {
          Self.logger.info("projectActivated fresh cache hit, skipping fetch")
          return .none
        }
        return enqueueProjectFetch(
          projectID: projectID, gitRoot: gitRoot, pairs: pairs, state: &state
        )

      case .projectRefreshRequested(let projectID, let gitRoot, let pairs):
        return enqueueProjectFetch(
          projectID: projectID, gitRoot: gitRoot, pairs: pairs, state: &state
        )

      case .projectBatchLoaded(let projectID, let pairs, .success(let batched)):
        Self.logger.info(
          "projectBatchLoaded success project=\(projectID.raw.uuidString, privacy: .public) branches=\(batched.byBranch.count, privacy: .public)/\(pairs.count, privacy: .public)"
        )
        state.inFlightFetchProjects.remove(projectID)
        state.loading.subtract(pairs.map(\.worktreeID))
        // Cancellation is cooperative, so a result dispatched before the
        // prune landed can still arrive. `projectGitRoots` is written by
        // every path that starts a fetch and removed only by
        // `pruneToCatalog`, so its absence means this Project left the
        // catalog mid-flight — writing the batch back would undo the prune
        // and re-persist a dead Project to disk.
        guard state.projectGitRoots[projectID] != nil else { return .none }
        state.lastErrorByProject[projectID] = nil
        state.snapshotsByProject[projectID] = batched
        // Best-effort persist to disk so the NEXT app launch hydrates instantly.
        let snapshotOnDisk = state.snapshotsByProject
        let cache = gitHubSnapshotCache
        let sequence = Self.cacheWriteSequence.next()
        Task.detached(priority: .utility) {
          cache.save(snapshotOnDisk, sequence)
        }
        // Project into per-Worktree `snapshots` so v1 view code keeps rendering
        // consistent data. Branches absent from `batched.byBranch` are dropped from
        // `snapshots` so a PR that was closed between fetches doesn't linger as stale.
        // Same reasoning one level down: the Project can survive while one of
        // its Worktrees is removed, and `pairs` was captured before that.
        for pair in pairs where state.projectByWorktree[pair.worktreeID] != nil {
          if let snap = batched.byBranch[pair.branch] {
            state.snapshots[pair.worktreeID] = snap
            state.snapshotLoadedAt[pair.worktreeID] = now
            state.lastError[pair.worktreeID] = nil
          } else {
            state.snapshots[pair.worktreeID] = nil
          }
        }
        // Drain any queued refresh for this Project.
        if state.queuedRefreshByProject.remove(projectID) != nil,
          let gitRoot = state.projectGitRoots[projectID]
        {
          // Current pairs, not the ones this request captured: a Worktree
          // removed while it was in flight is still in `pairs`, and
          // re-issuing with those would put it back into
          // `projectByWorktree` and `loading` — after which the next
          // result sails past the guards above and restores it.
          let currentPairs = state.projectWorktreePairs[projectID] ?? []
          return .send(
            .projectRefreshRequested(
              projectID, gitRoot: gitRoot, worktreeBranches: currentPairs
            )
          )
        }
        return .none

      case .projectBatchLoaded(let projectID, let pairs, .failure(let error)):
        Self.logger.error(
          "projectBatchLoaded failure project=\(projectID.raw.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
        state.inFlightFetchProjects.remove(projectID)
        state.loading.subtract(pairs.map(\.worktreeID))
        guard state.projectGitRoots[projectID] != nil else { return .none }
        state.lastErrorByProject[projectID] = (error as? GitHubError) ?? .other(String(describing: error))
        return .none

      // MARK: - active-Project liveness poll

      case .pollTargetChanged(let projectID, let gitRoot, let pairs):
        state.pollTarget = projectID
        guard let projectID else {
          return .cancel(id: CancelID.poll)
        }
        if let gitRoot { state.projectGitRoots[projectID] = gitRoot }
        state.projectWorktreePairs[projectID] = pairs
        for pair in pairs { state.projectByWorktree[pair.worktreeID] = projectID }
        // Arm only — the immediate refresh is owned by projectActivated / focus-gained.
        return schedulePollTick(
          projectID, after: Self.pollCadence(for: state.snapshotsByProject[projectID])
        )

      case .delayedProjectRefreshFired(let projectID):
        guard let gitRoot = state.projectGitRoots[projectID],
          let pairs = state.projectWorktreePairs[projectID]
        else {
          // The Project left the catalog while the timer ran.
          return .none
        }
        return enqueueProjectFetch(
          projectID: projectID, gitRoot: gitRoot, pairs: pairs, state: &state
        )

      case .pollTick(let projectID):
        // Defensive: cancellation normally prevents a stale tick from a prior target.
        guard state.pollTarget == projectID else { return .none }
        let cadence = Self.pollCadence(for: state.snapshotsByProject[projectID])
        guard let gitRoot = state.projectGitRoots[projectID],
          let pairs = state.projectWorktreePairs[projectID]
        else {
          // Lost the context to fetch (should not happen once a target is armed); keep
          // the loop alive so a later context write is picked up.
          return schedulePollTick(projectID, after: cadence)
        }
        let fetch = enqueueProjectFetch(
          projectID: projectID, gitRoot: gitRoot, pairs: pairs, state: &state
        )
        return .merge(fetch, schedulePollTick(projectID, after: cadence))

      case .pruneToCatalog(let projectIDs, let worktreeIDs):
        let hadProjects = state.snapshotsByProject.count
        // Fetches outlive the prune otherwise, and `projectBatchLoaded`
        // would write the removed Project's batch straight back into state
        // and on to disk.
        let departedInFlight = state.inFlightFetchProjects.subtracting(projectIDs)
        state.snapshots = state.snapshots.filter { worktreeIDs.contains($0.key) }
        state.snapshotLoadedAt = state.snapshotLoadedAt.filter { worktreeIDs.contains($0.key) }
        state.worktreePaths = state.worktreePaths.filter { worktreeIDs.contains($0.key) }
        state.lastError = state.lastError.filter { worktreeIDs.contains($0.key) }
        state.projectByWorktree = state.projectByWorktree.filter { worktreeIDs.contains($0.key) }
        state.loading.formIntersection(worktreeIDs)
        state.mutating.formIntersection(worktreeIDs)
        state.snapshotsByProject = state.snapshotsByProject.filter { projectIDs.contains($0.key) }
        state.lastErrorByProject = state.lastErrorByProject.filter { projectIDs.contains($0.key) }
        state.projectGitRoots = state.projectGitRoots.filter { projectIDs.contains($0.key) }
        // Nested pairs too, not just the Project key: a surviving Project's
        // stashed pairs still name a Worktree that just left, and every
        // re-issued fetch is parameterised by them.
        state.projectWorktreePairs = state.projectWorktreePairs
          .filter { projectIDs.contains($0.key) }
          .mapValues { $0.filter { worktreeIDs.contains($0.worktreeID) } }
        state.inFlightFetchProjects.formIntersection(projectIDs)
        state.queuedRefreshByProject.formIntersection(projectIDs)
        // Persist the pruned map so the removal survives a relaunch even if no
        // fetch succeeds before quit.
        if state.snapshotsByProject.count != hadProjects {
          let snapshotOnDisk = state.snapshotsByProject
          let cache = gitHubSnapshotCache
          let sequence = Self.cacheWriteSequence.next()
          Task.detached(priority: .utility) {
            cache.save(snapshotOnDisk, sequence)
          }
        }
        // A poll aimed at a Project that just left the catalog would keep
        // shelling out `git remote get-url` + `gh api graphql` against a
        // repository the user unregistered, and each success would write the
        // dead Project straight back into the on-disk cache.
        var effects = departedInFlight.map { Effect<Action>.cancel(id: CancelID.projectFetch($0)) }
        if let target = state.pollTarget, !projectIDs.contains(target) {
          state.pollTarget = nil
          effects.append(.cancel(id: CancelID.poll))
        }
        return .merge(effects)

      case .worktreeRefreshRequested(let worktreeID):
        guard let projectID = state.projectByWorktree[worktreeID],
          let gitRoot = state.projectGitRoots[projectID],
          let pairs = state.projectWorktreePairs[projectID]
        else { return .none }
        return enqueueProjectFetch(
          projectID: projectID, gitRoot: gitRoot, pairs: pairs, state: &state
        )

      // MARK: - delegate

      case .delegate:
        return .none
      }
    }
  }

  /// Kicks a batched fetch for the Project, honouring the in-flight guard. If another
  /// fetch is already running for the same Project, records a queue flag so the in-flight
  /// completion can dispatch a follow-up. Otherwise starts the subprocess chain, tagged
  /// with `CancelID.projectFetch(projectID)` so a subsequent call cancels the prior one.
  private func enqueueProjectFetch(
    projectID: ProjectID,
    gitRoot: URL,
    pairs: [Action.WorktreeBranchPair],
    state: inout State
  ) -> Effect<Action> {
    state.projectGitRoots[projectID] = gitRoot
    // Stash the pairs + worktree→project reverse map alongside the gitRoot so the poll
    // tick + post-mutation / retry refreshes can re-issue a fetch from a ProjectID or
    // WorktreeID alone. Written before the in-flight short-circuit so the maps stay
    // current even when this call collapses into the queued-refresh slot.
    state.projectWorktreePairs[projectID] = pairs
    for pair in pairs { state.projectByWorktree[pair.worktreeID] = projectID }
    // Marked before the in-flight short-circuit: a call that collapses into
    // the queued-refresh slot still has a fetch pending on its behalf.
    // Nothing wrote this set before, so the spinner the badge and popover
    // were built to show could never appear.
    state.loading.formUnion(pairs.map(\.worktreeID))
    if state.inFlightFetchProjects.contains(projectID) {
      state.queuedRefreshByProject.insert(projectID)
      return .none
    }
    state.inFlightFetchProjects.insert(projectID)
    let fetchedAt = now
    Self.logger.info(
      "enqueueProjectFetch project=\(projectID.raw.uuidString, privacy: .public) pairs=\(pairs.count, privacy: .public)"
    )
    return .run { [client = gitHubClient, gitService = gitServiceClient] send in
      let result = await TaskResult<BatchedPullRequests> {
        let remote: RemoteInfo
        do {
          remote = try await gitService.remoteInfo(gitRoot)
        } catch {
          Self.logger.error(
            "remoteInfo failed: \(String(describing: error), privacy: .public)"
          )
          throw GitHubError.remoteInfoUnavailable
        }
        Self.logger.info(
          "remoteInfo resolved host=\(remote.host, privacy: .public) owner=\(remote.owner, privacy: .public) repo=\(remote.repo, privacy: .public)"
        )
        let branches = pairs.map(\.branch)
        let seen = Set(branches)
        if branches.isEmpty {
          return BatchedPullRequests(
            host: remote.host, owner: remote.owner, repo: remote.repo,
            byBranch: [:], seenBranches: seen, fetchedAt: fetchedAt
          )
        }
        let byBranch = try await client.batchPullRequests(
          remote.host, remote.owner, remote.repo, branches
        )
        return BatchedPullRequests(
          host: remote.host, owner: remote.owner, repo: remote.repo,
          byBranch: byBranch, seenBranches: seen, fetchedAt: fetchedAt
        )
      }
      await send(.projectBatchLoaded(projectID, worktreeBranches: pairs, result))
    }
    .cancellable(id: CancelID.projectFetch(projectID), cancelInFlight: true)
  }

  /// Adaptive poll cadence for the active-Project liveness loop. Fast while any
  /// open PR has CI in flight or an unsettled merge state; slow otherwise. `nil` (no
  /// cached batch yet) is treated as settled — the first real fetch reclassifies it.
  static func pollCadence(for batched: BatchedPullRequests?) -> Duration {
    guard let batched else { return pollCadenceIdle }
    let inFlight = batched.byBranch.values.contains { snap in
      snap.state == .open
        && (snap.mergeStateStatus == .unknown
          || snap.checkRollup.contains { $0.status != .completed })
    }
    return inFlight ? pollCadenceActive : pollCadenceIdle
  }

  /// Single-slot re-arm timer for the liveness poll. `cancelInFlight: true` guarantees at
  /// most one live timer per app; a retarget / pause cancels the prior loop.
  private func schedulePollTick(
    _ projectID: ProjectID, after cadence: Duration
  ) -> Effect<Action> {
    .run { [clock] send in
      try await clock.sleep(for: cadence)
      await send(.pollTick(projectID))
    }
    .cancellable(id: CancelID.poll, cancelInFlight: true)
  }

  /// TTL for in-memory freshness. Under this window, repeat `projectActivated`
  /// dispatches for the same Project skip the fetch. Beyond it (including any
  /// disk-seeded cache from a prior launch — its `fetchedAt` is hours to days old),
  /// we always re-fetch so the user's second paint reflects whatever changed on
  /// GitHub's side since the cache was written. The cached snapshot is still used
  /// for the first paint — only the fetch decision toggles.
  static let projectCacheFreshness: TimeInterval = 30

  /// `true` iff the cached snapshot (1) exists, (2) was fetched within the freshness
  /// window, AND (3) covers exactly the current branch set. A false return means we
  /// should re-fetch — the cache is either missing, stale, or covers a different
  /// branch list. In-session repeats hit the cache; on-launch hydration from disk
  /// always misses on freshness and kicks the silent background refresh.
  private static func isCacheFreshAndComplete(
    cached: BatchedPullRequests?,
    current: [Action.WorktreeBranchPair],
    now: Date
  ) -> Bool {
    guard let cached else { return false }
    guard now.timeIntervalSince(cached.fetchedAt) < projectCacheFreshness else {
      return false
    }
    let currentBranches = Set(current.map(\.branch))
    return cached.seenBranches == currentBranches
  }

  // MARK: - Effect builders

  private func probeAvailabilityEffect() -> Effect<Action> {
    .run { send in
      let result = await gitHub.availability()
      await send(.availabilityProbed(result, probedAt: now))
    }
    .cancellable(id: CancelID.availabilityRefresh, cancelInFlight: true)
  }

  private func workflowRunFetchEffect(
    prNumber: Int, branch: String, worktreePath: URL
  ) -> Effect<Action> {
    .run { send in
      let result = await TaskResult<WorkflowRun?> {
        try await gitHub.latestWorkflowRun(branch, worktreePath)
      }
      await send(.workflowRunLoaded(prNumber: prNumber, result))
    }
    .cancellable(id: CancelID.workflowRun(prNumber: prNumber), cancelInFlight: true)
  }

  /// Re-fetches the owning Project after a mutation (merge / close / markReady / rerun)
  /// so every affected row in the repo reflects the new server state with a full check
  /// rollup — not the empty-checks single-branch v1 result. Resolves the Project from
  /// `projectByWorktree`; if the Worktree has not been part of a batched fetch yet,
  /// returns `.none` (the next `projectActivated` / poll tick will cover it). Delayed 2 s
  /// so GitHub has settled the write before we read it back.
  private func postMutationRefresh(
    worktreeID: WorktreeID, state: inout State
  ) -> Effect<Action> {
    guard let projectID = state.projectByWorktree[worktreeID] else { return .none }
    return .run { [clock] send in
      try await clock.sleep(for: .seconds(2))
      await send(.delayedProjectRefreshFired(projectID))
    }
    .cancellable(id: CancelID.delayedProjectRefresh(projectID), cancelInFlight: true)
  }

}

extension TaskResult where Success == GitHubFeature.Action.VoidSuccess {
  /// Convenience to keep the reducer's action construction terse.
  static var successVoid: TaskResult<GitHubFeature.Action.VoidSuccess> {
    .success(.init())
  }
}
