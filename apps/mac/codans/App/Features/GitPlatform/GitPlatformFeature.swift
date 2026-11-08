import CodansCore
import ComposableArchitecture
import Foundation
import os.log

/// The one reducer that owns the Pull Request fetch lifecycle for every Git Platform —
/// availability probe results, per-Worktree Pull Request snapshots, popover presentation,
/// and per-Worktree last-error for the inline banner. See ADR 0004 items 5 and 13.
///
/// It reaches Git Platforms only through `GitPlatformClient` and the provider-neutral model. It
/// does not branch on the Git Platform kind: each fetch unit's Git Platform is resolved from its
/// `origin` remote, kept on the unit's batch (`BatchedPullRequests.repository`), and every
/// call carries that repository so the client selects the implementation.
///
/// Mutations flow through explicit Requested → Completed action pairs (merge / close /
/// markReady / rerunFailedChecks). The Completed branch schedules a delayed project-level
/// refresh to pick up the new server state without hammering the Git Platform.
@Reducer
struct GitPlatformFeature {
  /// A merge refused because the head moved, and whether the new head has been read.
  struct HeadMovedMerge: Equatable, Sendable {
    var pullRequestNumber: Int
    var branch: String
    var refusedAt: Date
    /// `true` after a successful fetch that started after the refusal and still has this
    /// Pull Request. Only then does "Review" show the new head.
    var isNewHeadRead = false
  }

  @ObservableState
  struct State: Equatable {
    var availability: [GitPlatformKind: GitPlatformAvailability] = [:]
    var availabilityProbedAt: Date?

    var snapshots: [WorktreeID: PullRequestSnapshot] = [:]
    var snapshotLoadedAt: [WorktreeID: Date] = [:]

    /// Worktrees whose owning Project has a batched fetch in flight (or
    /// queued behind one). Only the popover renders a spinner from this; the
    /// sidebar row never shows one.
    var loading: Set<WorktreeID> = []

    /// Mutation operations in flight per Worktree. Views observe this to disable the
    /// matching popover button so repeated clicks can't fire multiple `gh` subprocesses.
    var mutating: Set<WorktreeID> = []

    /// Which Worktree's popover is visible. `nil` ⇒ no popover.
    var popoverTarget: WorktreeID?

    /// Per-Worktree last-seen error, cleared on successful refresh.
    var lastError: [WorktreeID: GitPlatformError] = [:]

    /// Merges the Git Platform refused because the head moved, per Worktree. While one is
    /// here, `lastError` is `.headMoved` and a refresh does not clear it. It goes when the
    /// user reviews the new head, or when the Worktree no longer shows that Pull Request
    /// (other branch, other number). See ADR 0004 item 17.
    var headMovedMerges: [WorktreeID: HeadMovedMerge] = [:]

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
    /// Not shown per row.
    var lastErrorByProject: [ProjectID: GitPlatformError] = [:]

    /// Fetch units whose `origin` host no Git Platform serves. They show no badge and no
    /// error, and the poll skips them; an event-driven refresh resolves them again.
    var unitsWithoutGitPlatform: Set<ProjectID> = []

    /// Last-known gitRoot per Project. Stashed so the queued-refresh drain + the
    /// delayed post-mutation refresh can re-issue a fetch without the caller re-passing
    /// the gitRoot. Not yet cleared when the Project is removed from the catalog.
    var projectGitRoots: [ProjectID: URL] = [:]

    // MARK: - liveness poll

    /// Fetch units the foreground poll covers: every unit of every Project in the
    /// catalog. Replaced whole by `pollUnitsChanged`.
    var pollUnits: Set<ProjectID> = []

    /// Units of the selected Project. They poll on the faster selected-tier cadence.
    var selectedUnits: Set<ProjectID> = []

    /// `true` while the app is frontmost. The poll timer runs only then.
    var isPolling = false

    /// When the latest batched fetch for a unit started. Drives the per-unit cadence and
    /// the focus-gained catch-up debounce. Written whenever a fetch starts, whatever
    /// asked for it, so an event-driven fetch also resets the unit's poll clock.
    var lastFetchStartedAt: [ProjectID: Date] = [:]

    /// Units owed a fetch regardless of cadence (focus-gained catch-up, refresh-all).
    /// Drained by the scheduler at most `maxConcurrentPollFetches` at a time.
    var pendingPollRefresh: Set<ProjectID> = []

    /// Units that poll as `.hot` until the stored time, whatever their batch says.
    /// Set when a unit's remote-tracking refs move: a push is often followed by
    /// `gh pr create` and CI starting, which a settled-tier cadence would show late.
    var hotUntil: [ProjectID: Date] = [:]

    /// Last-known branch pairs per Project, so a poll tick — or a post-mutation /
    /// manual-retry refresh — can re-issue a fetch without the caller re-supplying them.
    /// Written everywhere `projectGitRoots[P]` is written (inside `enqueueProjectFetch`)
    /// and on `pollUnitsChanged`.
    var projectWorktreePairs: [ProjectID: [Action.WorktreeBranchPair]] = [:]

    /// Worktree → owning Project. Lets `postMutationRefresh` + the badge/popover retry
    /// resolve a project-level batched fetch from a `WorktreeID` alone.
    var projectByWorktree: [WorktreeID: ProjectID] = [:]

    /// PR-number ↔ Worktree map derived from `snapshots`. Keeps lookup O(1) for action
    /// completion handlers that only know the PR number.
    func worktree(for prNumber: Int) -> WorktreeID? {
      snapshots.first(where: { $0.value.number == prNumber })?.key
    }

    /// The Git Platform repository of the Worktree's fetch unit, from its latest batch.
    func repository(for worktreeID: WorktreeID) -> GitPlatformRepository? {
      projectByWorktree[worktreeID].flatMap { snapshotsByProject[$0]?.repository }
    }

    /// The Pull Request the Worktree's row shows, as a reference write actions take.
    func pullRequestReference(for worktreeID: WorktreeID) -> PullRequestReference? {
      guard let snapshot = snapshots[worktreeID], let repository = repository(for: worktreeID)
      else { return nil }
      return PullRequestReference(repository: repository, number: snapshot.number)
    }
  }

  /// Monotonic stamp handed to every on-disk cache write so a save that
  /// started earlier cannot land after a newer one. See
  /// `PullRequestSnapshotCache.save(_:sequence:)`.
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
    case availabilityProbed([GitPlatformKind: GitPlatformAvailability], probedAt: Date)

    case presentPopover(WorktreeID)
    case dismissPopover
    /// A Pull Request popover appeared, from any surface (sidebar badge or status bar).
    case popoverOpened(WorktreeID)

    /// `headSHA` is the head commit of the snapshot the user saw. `nil` (a snapshot from
    /// an older cache entry) refreshes the unit and does not merge (ADR 0004 item 17).
    case mergeRequested(WorktreeID, PullRequestReference, strategy: MergeStrategy, headSHA: String?)
    case mergeCompleted(WorktreeID, prNumber: Int, TaskResult<VoidSuccess>)
    /// The user selected "Review" on the `.headMoved` error. Shows the new head when it
    /// has been read; otherwise reads it again.
    case headMovedReviewed(WorktreeID)

    case closeRequested(WorktreeID, PullRequestReference)
    case closeCompleted(WorktreeID, TaskResult<VoidSuccess>)

    case markReadyRequested(WorktreeID, PullRequestReference)
    case markReadyCompleted(WorktreeID, TaskResult<VoidSuccess>)

    case rerunFailedChecksRequested(WorktreeID, PullRequestReference)
    case rerunFailedChecksCompleted(WorktreeID, TaskResult<VoidSuccess>)

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

    /// Force a fresh batched fetch for the Project, respecting the in-flight + queued
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

    /// The unit's `origin` host is served by no Git Platform. The fetch stops before any
    /// Git Platform call; the unit's rows show no badge and no error.
    case gitPlatformUnresolved(ProjectID, worktreeBranches: [WorktreeBranchPair])

    /// The unit resolved to another Git Platform repository than its cached batch (a changed
    /// Project Git Platform choice, a CLI login, or a new `origin`). Sent before the read, so
    /// the old Pull Requests go even when the read of the new repository fails.
    case gitPlatformRepositoryChanged(ProjectID, worktreeBranches: [WorktreeBranchPair])

    // MARK: - liveness poll

    /// Replace the set of units the foreground poll covers, and mark which belong to the
    /// selected Project. Also refreshes each unit's stashed gitRoot and branch pairs, so
    /// later event-driven refreshes use the current branch set. Starts any fetch that is
    /// already due when the poll is running.
    case pollUnitsChanged([FetchUnit], selected: Set<ProjectID>)

    /// The app became frontmost (`true`) or resigned (`false`). Resuming queues a
    /// catch-up fetch for each unit not fetched within `focusRefreshDebounce`; pausing
    /// cancels the timer so a background app runs no Git Platform subprocess.
    case appActiveChanged(Bool)

    /// One beat of the poll timer. Starts the due fetches and re-arms the timer.
    case pollTick

    /// Queue a fetch for every polled unit, drained through the concurrency cap.
    case refreshAllRequested

    /// The unit's remote-tracking refs changed on disk (`git push` / `git fetch`
    /// from any process). Schedules a short-delay refresh and polls the unit as
    /// `.hot` for `remoteRefsHotWindow`.
    case remoteRefsChanged(ProjectID)

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
      /// Git Platform section.
      case showGitPlatformSettings
      /// Open a Git Platform URL in the default browser.
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

  /// One batched Pull Request fetch: the repository to ask about and the rows whose
  /// branches to ask for. A git Project is one unit keyed by its own id; a workspace has
  /// one unit per member repository (see `RootFeature.gitPlatformFetchUnits`).
  nonisolated struct FetchUnit: Equatable, Sendable {
    let projectID: ProjectID
    let gitRoot: URL
    let pairs: [Action.WorktreeBranchPair]
  }

  nonisolated enum CancelID: Hashable, Sendable {
    case availabilityRefresh
    /// One-cancellation-slot for all mutations on a Worktree so a second click while an
    /// operation is in flight cancels the prior run rather than racing it.
    case mutation(WorktreeID)
    /// Per-Project batched fetch. Re-dispatching `projectRefreshRequested`
    /// for an in-flight Project cancels the prior fetch and replaces it.
    case projectFetch(ProjectID)
    /// Delayed refresh — merge / close / markReady / rerun schedule it 2 s after a
    /// successful write; a remote-refs change schedules it too.
    case delayedProjectRefresh(ProjectID)
    /// Single re-arm slot for the liveness poll timer. Every re-arm and the pause
    /// cancel the prior timer so at most one is ever live.
    case poll
  }

  /// Availability result is treated as fresh for 30 s; subsequent `onAppear` / visibility
  /// dispatches within the window skip the probe.
  static let availabilityFreshness: TimeInterval = 30

  // MARK: - liveness poll cadence

  /// How much a unit has in motion, judged from its latest batch. Picks the poll cadence.
  enum PollTier: Equatable {
    /// An open PR has CI in flight or an unsettled merge state.
    case hot
    /// Open PRs, all settled.
    case warm
    /// No open PR, or nothing fetched yet.
    case cold
  }

  /// Poll cadence per tier. The selected Project polls fastest; other Projects still
  /// poll while the app is frontmost, so a PR an agent opens or CI finishing in another
  /// Project shows without a switch to it.
  static func pollInterval(_ tier: PollTier, selected: Bool) -> TimeInterval {
    switch (tier, selected) {
    case (.hot, true): 10
    case (.warm, true): 30
    case (.cold, true): 60
    case (.hot, false): 30
    case (.warm, false): 120
    case (.cold, false): 300
    }
  }

  /// On focus gained, units not fetched within this window get a catch-up fetch.
  static let focusRefreshDebounce: TimeInterval = 30

  /// Most poll-started fetches in flight at once. Event-driven fetches do not count
  /// against it; the cap only spreads a catch-up across many Projects.
  static let maxConcurrentPollFetches = 2

  /// How long a remote-refs change keeps a unit on the `.hot` cadence. Long enough
  /// to cover an agent opening the PR some time after its push.
  static let remoteRefsHotWindow: TimeInterval = 180

  /// Bounds on the timer delay. The floor stops a busy loop; the ceiling bounds how
  /// late a cadence change is noticed.
  static let minPollDelay: TimeInterval = 1
  static let maxPollDelay: TimeInterval = 60

  @Dependency(GitPlatformClient.self) var gitPlatform
  /// Reads `git remote get-url origin` for each fetch unit; the Git Platform client resolves
  /// it to a Git Platform repository.
  @Dependency(GitServiceClient.self) var gitServiceClient
  /// The Git Platform aliases from Settings, read when a fetch starts (ADR 0005).
  @Dependency(GitPlatformAliasesClient.self) var gitPlatformAliases
  /// Persists the project-batched PR cache across launches so the sidebar paints
  /// immediately instead of flashing empty → populated as fetches return.
  @Dependency(PullRequestSnapshotCacheClient.self) var pullRequestSnapshotCache
  @Dependency(\.date.now) var now
  /// Drives the liveness-poll re-arm timer + the post-mutation refresh delay. TestStore
  /// overrides this with a controllable clock.
  @Dependency(\.continuousClock) var clock

  nonisolated static let logger = Logger(subsystem: "com.gumpw.codans.gitplatform", category: "feature")

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {

      // MARK: - availability

      case .onAppear:
        if let probedAt = state.availabilityProbedAt,
          now.timeIntervalSince(probedAt) < Self.availabilityFreshness,
          GitPlatformKind.allCases.allSatisfy({ state.availability[$0]?.isAvailable == true })
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
        // A fresh `auth login` can make a self-managed host resolvable.
        state.unitsWithoutGitPlatform = []
        // The probe waits for the invalidation, or it can read and cache for 30 s the
        // CLI path and logged-in hosts from before an install or `auth login`.
        return probeAvailabilityEffect(invalidatingFirst: true)

      case .availabilityProbed(let result, let probedAt):
        state.availability = result
        state.availabilityProbedAt = probedAt
        return .none

      // MARK: - popover

      case .presentPopover(let worktreeID):
        state.popoverTarget = worktreeID
        return .none

      case .popoverOpened(let worktreeID):
        // A snapshot without a head commit cannot merge; read the head now.
        guard let snapshot = state.snapshots[worktreeID], snapshot.state == .open, snapshot.headSHA == nil
        else { return .none }
        return refreshUnit(of: worktreeID, state: &state)

      case .dismissPopover:
        state.popoverTarget = nil
        return .none

      // MARK: - merge

      case .mergeRequested(let worktreeID, let pullRequest, let strategy, let headSHA):
        if state.mutating.contains(worktreeID) { return .none }  // already running
        // Never merge a head the user did not see: read it first, then the user merges
        // again from the refreshed popover.
        guard let headSHA else { return refreshUnit(of: worktreeID, state: &state) }
        state.mutating.insert(worktreeID)
        return .run { [gitPlatform] send in
          let result = await TaskResult<Action.VoidSuccess> {
            try await gitPlatform.merge(pullRequest, strategy, headSHA)
            return Action.VoidSuccess()
          }
          await send(.mergeCompleted(worktreeID, prNumber: pullRequest.number, result))
        }
        .cancellable(id: CancelID.mutation(worktreeID), cancelInFlight: true)

      case .mergeCompleted(let worktreeID, _, .success):
        state.mutating.remove(worktreeID)
        state.headMovedMerges[worktreeID] = nil
        // Delegate pullRequestMerged so RootFeature can trigger the post-merge action,
        // then kick off a refresh so the badge flips to merged on its own.
        let refresh = postMutationRefresh(worktreeID: worktreeID, state: &state)
        if let snapshot = state.snapshots[worktreeID] {
          return .merge(.send(.delegate(.pullRequestMerged(worktreeID, snapshot: snapshot))), refresh)
        }
        return refresh

      case .mergeCompleted(let worktreeID, let prNumber, .failure(let error)):
        state.mutating.remove(worktreeID)
        let gitPlatformError = Self.gitPlatformError(error)
        state.lastError[worktreeID] = gitPlatformError
        guard gitPlatformError == .headMoved, let snapshot = state.snapshots[worktreeID] else {
          state.headMovedMerges[worktreeID] = nil
          return .none
        }
        // Read the new head at once. The error stays through this refresh, so the user
        // reads it first (see `projectBatchLoaded`).
        state.headMovedMerges[worktreeID] = HeadMovedMerge(
          pullRequestNumber: prNumber, branch: snapshot.headRefName, refusedAt: now)
        return refreshUnit(of: worktreeID, state: &state)

      case .headMovedReviewed(let worktreeID):
        guard let merge = state.headMovedMerges[worktreeID] else {
          Self.clearHeadMoved(worktreeID, state: &state)
          return .none
        }
        // Before the new head is read (refresh pending or failed), the old snapshot is all
        // there is to show: read again instead.
        guard merge.isNewHeadRead else { return refreshUnit(of: worktreeID, state: &state) }
        Self.clearHeadMoved(worktreeID, state: &state)
        return .none

      // MARK: - close

      case .closeRequested(let worktreeID, let pullRequest):
        return mutationEffect(worktreeID: worktreeID, state: &state) { [gitPlatform] in
          try await gitPlatform.close(pullRequest)
        } completed: { .closeCompleted(worktreeID, $0) }

      case .closeCompleted(let worktreeID, .failure(let error)):
        state.mutating.remove(worktreeID)
        state.lastError[worktreeID] = Self.gitPlatformError(error)
        return .none

      case .closeCompleted(let worktreeID, _):
        state.mutating.remove(worktreeID)
        return postMutationRefresh(worktreeID: worktreeID, state: &state)

      // MARK: - markReady

      case .markReadyRequested(let worktreeID, let pullRequest):
        return mutationEffect(worktreeID: worktreeID, state: &state) { [gitPlatform] in
          try await gitPlatform.markReady(pullRequest)
        } completed: { .markReadyCompleted(worktreeID, $0) }

      case .markReadyCompleted(let worktreeID, .failure(let error)):
        state.mutating.remove(worktreeID)
        state.lastError[worktreeID] = Self.gitPlatformError(error)
        return .none

      case .markReadyCompleted(let worktreeID, _):
        state.mutating.remove(worktreeID)
        return postMutationRefresh(worktreeID: worktreeID, state: &state)

      // MARK: - rerunFailedChecks

      case .rerunFailedChecksRequested(let worktreeID, let pullRequest):
        return mutationEffect(worktreeID: worktreeID, state: &state) { [gitPlatform] in
          try await gitPlatform.rerunFailedChecks(pullRequest)
        } completed: { .rerunFailedChecksCompleted(worktreeID, $0) }

      case .rerunFailedChecksCompleted(let worktreeID, .failure(let error)):
        state.mutating.remove(worktreeID)
        state.lastError[worktreeID] = Self.gitPlatformError(error)
        return .none

      case .rerunFailedChecksCompleted(let worktreeID, _):
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
        state.unitsWithoutGitPlatform.remove(projectID)
        state.snapshotsByProject[projectID] = batched
        // Best-effort persist to disk so the NEXT app launch hydrates instantly.
        let snapshotOnDisk = state.snapshotsByProject
        let cache = pullRequestSnapshotCache
        let sequence = Self.cacheWriteSequence.next()
        Task.detached(priority: .utility) {
          cache.save(snapshotOnDisk, sequence)
        }
        // Project into per-Worktree `snapshots` so v1 view code keeps rendering
        // consistent data. Branches absent from `batched.byBranch` are dropped from
        // `snapshots` so a PR that was closed between fetches doesn't linger as stale.
        // Same reasoning one level down: the Project can survive while one of
        // its Worktrees is removed, and `pairs` was captured before that.
        let fetchStartedAt = state.lastFetchStartedAt[projectID] ?? .distantPast
        for pair in pairs where state.projectByWorktree[pair.worktreeID] != nil {
          // `.headMoved` is the answer to a merge, not to a read: it stays until the user
          // reviews the new head, while the row still shows the refused Pull Request.
          if let merge = state.headMovedMerges[pair.worktreeID], merge.branch == pair.branch,
            batched.byBranch[pair.branch]?.number == merge.pullRequestNumber
          {
            if fetchStartedAt >= merge.refusedAt { state.headMovedMerges[pair.worktreeID]?.isNewHeadRead = true }
            // A failed read in between can have put a CLI error in its place.
            state.lastError[pair.worktreeID] = .headMoved
          } else {
            state.headMovedMerges[pair.worktreeID] = nil
            state.lastError[pair.worktreeID] = nil
          }
          if let snap = batched.byBranch[pair.branch] {
            state.snapshots[pair.worktreeID] = snap
            state.snapshotLoadedAt[pair.worktreeID] = now
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
          return .merge(
            .send(
              .projectRefreshRequested(
                projectID, gitRoot: gitRoot, worktreeBranches: currentPairs
              )
            ),
            drainPollSlot(state: &state)
          )
        }
        return drainPollSlot(state: &state)

      case .projectBatchLoaded(let projectID, let pairs, .failure(let error)):
        Self.logger.error(
          "projectBatchLoaded failure project=\(projectID.raw.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
        state.inFlightFetchProjects.remove(projectID)
        state.loading.subtract(pairs.map(\.worktreeID))
        guard state.projectGitRoots[projectID] != nil else { return .none }
        let gitPlatformError = Self.gitPlatformError(error)
        state.lastErrorByProject[projectID] = gitPlatformError
        // The user can fix a CLI error (install, log in, upgrade), so each row shows it at
        // its badge position, as the popover's actionable message (ADR 0004 item 15).
        // Other batch errors are transient; the rows keep what they show.
        if gitPlatformError.isCLIError {
          for pair in pairs where state.projectByWorktree[pair.worktreeID] != nil {
            state.lastError[pair.worktreeID] = gitPlatformError
          }
        }
        return drainPollSlot(state: &state)

      case .gitPlatformUnresolved(let projectID, let pairs):
        Self.logger.info(
          "gitPlatformUnresolved project=\(projectID.raw.uuidString, privacy: .public)"
        )
        state.inFlightFetchProjects.remove(projectID)
        state.loading.subtract(pairs.map(\.worktreeID))
        guard state.projectGitRoots[projectID] != nil else { return .none }
        state.unitsWithoutGitPlatform.insert(projectID)
        state.queuedRefreshByProject.remove(projectID)
        dropUnitSnapshots(projectID, pairs: pairs, state: &state)
        return drainPollSlot(state: &state)

      case .gitPlatformRepositoryChanged(let projectID, let pairs):
        Self.logger.info(
          "gitPlatformRepositoryChanged project=\(projectID.raw.uuidString, privacy: .public)"
        )
        // The fetch for the new repository is still in flight; only what belongs to the
        // old repository goes.
        guard state.projectGitRoots[projectID] != nil else { return .none }
        dropUnitSnapshots(projectID, pairs: pairs, state: &state)
        return .none

      // MARK: - active-Project liveness poll

      case .pollUnitsChanged(let units, let selected):
        state.pollUnits = Set(units.map(\.projectID))
        state.selectedUnits = selected.intersection(state.pollUnits)
        state.pendingPollRefresh.formIntersection(state.pollUnits)
        for unit in units {
          state.projectGitRoots[unit.projectID] = unit.gitRoot
          state.projectWorktreePairs[unit.projectID] = unit.pairs
          for pair in unit.pairs { state.projectByWorktree[pair.worktreeID] = unit.projectID }
          Self.reprojectCachedSnapshots(unit.projectID, pairs: unit.pairs, state: &state)
        }
        return state.isPolling ? runPollScheduler(state: &state) : .none

      case .appActiveChanged(let isActive):
        state.isPolling = isActive
        guard isActive else { return .cancel(id: CancelID.poll) }
        for projectID in state.pollUnits where !state.unitsWithoutGitPlatform.contains(projectID) {
          let started = state.lastFetchStartedAt[projectID] ?? .distantPast
          if now.timeIntervalSince(started) >= Self.focusRefreshDebounce {
            state.pendingPollRefresh.insert(projectID)
          }
        }
        return runPollScheduler(state: &state)

      case .pollTick:
        guard state.isPolling else { return .none }
        return runPollScheduler(state: &state)

      case .refreshAllRequested:
        state.pendingPollRefresh = state.pollUnits
        return runPollScheduler(state: &state)

      case .remoteRefsChanged(let projectID):
        guard state.pollUnits.contains(projectID) else { return .none }
        state.hotUntil[projectID] = now.addingTimeInterval(Self.remoteRefsHotWindow)
        // The ref moves when the push lands; a `gh pr create` wrapping it opens
        // the PR right after, so give the Git Platform a moment before reading back.
        return scheduleDelayedRefresh(projectID)

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

      case .pruneToCatalog(let projectIDs, let worktreeIDs):
        let hadProjects = state.snapshotsByProject.count
        // Fetches outlive the prune otherwise, and `projectBatchLoaded`
        // would write the removed Project's batch straight back into state
        // and on to disk.
        let departedInFlight = state.inFlightFetchProjects.subtracting(projectIDs)
        state.snapshots = state.snapshots.filter { worktreeIDs.contains($0.key) }
        state.snapshotLoadedAt = state.snapshotLoadedAt.filter { worktreeIDs.contains($0.key) }
        state.lastError = state.lastError.filter { worktreeIDs.contains($0.key) }
        state.headMovedMerges = state.headMovedMerges.filter { worktreeIDs.contains($0.key) }
        state.projectByWorktree = state.projectByWorktree.filter { worktreeIDs.contains($0.key) }
        state.loading.formIntersection(worktreeIDs)
        state.mutating.formIntersection(worktreeIDs)
        state.snapshotsByProject = state.snapshotsByProject.filter { projectIDs.contains($0.key) }
        state.lastErrorByProject = state.lastErrorByProject.filter { projectIDs.contains($0.key) }
        state.unitsWithoutGitPlatform.formIntersection(projectIDs)
        state.projectGitRoots = state.projectGitRoots.filter { projectIDs.contains($0.key) }
        // Nested pairs too, not just the Project key: a surviving Project's
        // stashed pairs still name a Worktree that just left, and every
        // re-issued fetch is parameterised by them.
        state.projectWorktreePairs = state.projectWorktreePairs
          .filter { projectIDs.contains($0.key) }
          .mapValues { $0.filter { worktreeIDs.contains($0.worktreeID) } }
        state.inFlightFetchProjects.formIntersection(projectIDs)
        state.queuedRefreshByProject.formIntersection(projectIDs)
        state.pollUnits.formIntersection(projectIDs)
        state.selectedUnits.formIntersection(projectIDs)
        state.pendingPollRefresh.formIntersection(projectIDs)
        state.lastFetchStartedAt = state.lastFetchStartedAt.filter { projectIDs.contains($0.key) }
        state.hotUntil = state.hotUntil.filter { projectIDs.contains($0.key) }
        // Persist the pruned map so the removal survives a relaunch even if no
        // fetch succeeds before quit.
        if state.snapshotsByProject.count != hadProjects {
          let snapshotOnDisk = state.snapshotsByProject
          let cache = pullRequestSnapshotCache
          let sequence = Self.cacheWriteSequence.next()
          Task.detached(priority: .utility) {
            cache.save(snapshotOnDisk, sequence)
          }
        }
        // Dropping a departed unit from `pollUnits` above stops the poll from
        // querying the Git Platform about a repository the user unregistered, and
        // each success writing it back into the disk cache.
        return .merge(departedInFlight.map { Effect<Action>.cancel(id: CancelID.projectFetch($0)) })

      case .worktreeRefreshRequested(let worktreeID):
        return refreshUnit(of: worktreeID, state: &state)

      // MARK: - delegate

      case .delegate:
        return .none
      }
    }
  }

  /// Forgets the unit's batch and its rows' Pull Requests and errors, and writes the
  /// snapshot cache without the unit.
  private func dropUnitSnapshots(
    _ projectID: ProjectID, pairs: [Action.WorktreeBranchPair], state: inout State
  ) {
    state.lastErrorByProject[projectID] = nil
    for pair in pairs {
      state.snapshots[pair.worktreeID] = nil
      state.snapshotLoadedAt[pair.worktreeID] = nil
      state.lastError[pair.worktreeID] = nil
      state.headMovedMerges[pair.worktreeID] = nil
    }
    guard state.snapshotsByProject.removeValue(forKey: projectID) != nil else { return }
    let snapshotOnDisk = state.snapshotsByProject
    let cache = pullRequestSnapshotCache
    let sequence = Self.cacheWriteSequence.next()
    Task.detached(priority: .utility) {
      cache.save(snapshotOnDisk, sequence)
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
    Self.reprojectCachedSnapshots(projectID, pairs: pairs, state: &state)
    // The popover's spinner means "nothing known yet", so only a Project's
    // first fetch marks its Worktrees. A refresh over a cached batch — poll
    // ticks, the post-mutation refetch, a fresh-on-activation miss — runs
    // silently; the popover keeps showing what it knows until the new batch
    // lands.
    // Marked before the in-flight short-circuit: a call that collapses into
    // the queued-refresh slot still has a fetch pending on its behalf.
    if state.snapshotsByProject[projectID] == nil {
      state.loading.formUnion(pairs.map(\.worktreeID))
    }
    if state.inFlightFetchProjects.contains(projectID) {
      state.queuedRefreshByProject.insert(projectID)
      return .none
    }
    state.inFlightFetchProjects.insert(projectID)
    let fetchedAt = now
    state.lastFetchStartedAt[projectID] = fetchedAt
    state.pendingPollRefresh.remove(projectID)
    Self.logger.info(
      "enqueueProjectFetch project=\(projectID.raw.uuidString, privacy: .public) pairs=\(pairs.count, privacy: .public)"
    )
    let cachedRepository = state.snapshotsByProject[projectID]?.repository
    return .run { [gitPlatform, gitService = gitServiceClient, gitPlatformAliases] send in
      let remote: RemoteInfo
      do {
        remote = try await gitService.remoteInfo(gitRoot)
      } catch {
        Self.logger.error(
          "remoteInfo failed: \(String(describing: error), privacy: .public)"
        )
        await send(
          .projectBatchLoaded(
            projectID, worktreeBranches: pairs, .failure(GitPlatformError.remoteInfoUnavailable)))
        return
      }
      guard let repository = await gitPlatform.resolveRepository(remote, await gitPlatformAliases.aliases()) else {
        await send(.gitPlatformUnresolved(projectID, worktreeBranches: pairs))
        return
      }
      Self.logger.info(
        "repository resolved kind=\(repository.kind.rawValue, privacy: .public) host=\(repository.host, privacy: .public) path=\(repository.path, privacy: .public)"
      )
      if let cachedRepository, cachedRepository != repository {
        await send(.gitPlatformRepositoryChanged(projectID, worktreeBranches: pairs))
      }
      let result = await TaskResult<BatchedPullRequests> {
        let branches = pairs.map(\.branch)
        let seen = Set(branches)
        if branches.isEmpty {
          return BatchedPullRequests(
            repository: repository, byBranch: [:], seenBranches: seen, fetchedAt: fetchedAt
          )
        }
        let byBranch = try await gitPlatform.batchPullRequests(repository, branches)
        return BatchedPullRequests(
          repository: repository, byBranch: byBranch, seenBranches: seen, fetchedAt: fetchedAt
        )
      }
      await send(.projectBatchLoaded(projectID, worktreeBranches: pairs, result))
    }
    .cancellable(id: CancelID.projectFetch(projectID), cancelInFlight: true)
  }

  /// Classifies a unit's latest batch. `nil` (nothing fetched yet) is cold; the first
  /// real fetch reclassifies it.
  static func pollTier(for batched: BatchedPullRequests?) -> PollTier {
    let open = batched?.byBranch.values.filter { $0.state == .open } ?? []
    if open.isEmpty { return .cold }
    let inFlight = open.contains { snap in
      snap.mergeState.status == .unknown || snap.checkRollup.contains { $0.status != .completed }
    }
    return inFlight ? .hot : .warm
  }

  private static func pollInterval(_ projectID: ProjectID, state: State, now: Date) -> TimeInterval {
    let hot = state.hotUntil[projectID].map { now < $0 } ?? false
    return pollInterval(
      hot ? .hot : pollTier(for: state.snapshotsByProject[projectID]),
      selected: state.selectedUnits.contains(projectID))
  }

  /// Starts the due poll fetches, then re-arms the timer for the next due unit. A unit
  /// is due when it is owed a catch-up (`pendingPollRefresh`) or its cadence elapsed
  /// since its last fetch started. Selected units go first, then the least recently
  /// fetched; at most `maxConcurrentPollFetches` fetches run at once.
  private func runPollScheduler(state: inout State) -> Effect<Action> {
    let fetches = startDuePollFetches(state: &state)
    // No unit, no timer: `pollUnitsChanged` re-runs the scheduler when units arrive.
    guard state.isPolling, !state.pollUnits.isEmpty else { return fetches }
    return .merge(fetches, schedulePollTick(after: nextPollDelay(state: state)))
  }

  /// A fetch finished and freed a slot. Hands the slot to the next due unit so a
  /// catch-up over many Projects does not wait for the timer.
  private func drainPollSlot(state: inout State) -> Effect<Action> {
    guard state.isPolling || !state.pendingPollRefresh.isEmpty else { return .none }
    return runPollScheduler(state: &state)
  }

  private func startDuePollFetches(state: inout State) -> Effect<Action> {
    let polling = state.isPolling
    let due = state.pollUnits.filter { projectID in
      guard !state.inFlightFetchProjects.contains(projectID) else { return false }
      if state.pendingPollRefresh.contains(projectID) { return true }
      // A unit no Git Platform serves has nothing to poll for.
      guard polling, !state.unitsWithoutGitPlatform.contains(projectID) else { return false }
      let started = state.lastFetchStartedAt[projectID] ?? .distantPast
      return now.timeIntervalSince(started) >= Self.pollInterval(projectID, state: state, now: now)
    }
    let ordered = due.sorted { lhs, rhs in
      let lhsSelected = state.selectedUnits.contains(lhs)
      let rhsSelected = state.selectedUnits.contains(rhs)
      if lhsSelected != rhsSelected { return lhsSelected }
      let lhsStarted = state.lastFetchStartedAt[lhs] ?? .distantPast
      let rhsStarted = state.lastFetchStartedAt[rhs] ?? .distantPast
      if lhsStarted != rhsStarted { return lhsStarted < rhsStarted }
      return lhs.raw.uuidString < rhs.raw.uuidString
    }
    let pollInFlight = state.inFlightFetchProjects.intersection(state.pollUnits).count
    let slots = max(0, Self.maxConcurrentPollFetches - pollInFlight)
    var effects: [Effect<Action>] = []
    for projectID in ordered.prefix(slots) {
      guard let gitRoot = state.projectGitRoots[projectID],
        let pairs = state.projectWorktreePairs[projectID]
      else {
        state.pendingPollRefresh.remove(projectID)
        continue
      }
      effects.append(
        enqueueProjectFetch(projectID: projectID, gitRoot: gitRoot, pairs: pairs, state: &state))
    }
    return .merge(effects)
  }

  /// Delay until the earliest idle unit is due, clamped to `minPollDelay ...
  /// maxPollDelay`. In-flight units are skipped: their completion re-runs the scheduler.
  private func nextPollDelay(state: State) -> TimeInterval {
    var delay = Self.maxPollDelay
    for projectID in state.pollUnits where !state.inFlightFetchProjects.contains(projectID) {
      if state.pendingPollRefresh.contains(projectID) {
        delay = Self.minPollDelay
        break
      }
      if state.unitsWithoutGitPlatform.contains(projectID) { continue }
      let started = state.lastFetchStartedAt[projectID] ?? .distantPast
      let remaining = Self.pollInterval(projectID, state: state, now: now) - now.timeIntervalSince(started)
      delay = min(delay, remaining)
    }
    return min(max(delay, Self.minPollDelay), Self.maxPollDelay)
  }

  /// Single-slot re-arm timer for the liveness poll. `cancelInFlight: true` keeps at
  /// most one live timer per app; a re-arm or pause cancels the prior one.
  private func schedulePollTick(after delay: TimeInterval) -> Effect<Action> {
    .run { [clock] send in
      try await clock.sleep(for: .milliseconds(Int((delay * 1000).rounded(.up))))
      await send(.pollTick)
    }
    .cancellable(id: CancelID.poll, cancelInFlight: true)
  }

  /// Keeps each row's PR badge on its current branch before the next fetch lands. A
  /// row whose snapshot names a different branch (the worktree switched branches)
  /// takes the cached batch's entry for the new branch, or no badge.
  private static func reprojectCachedSnapshots(
    _ projectID: ProjectID, pairs: [Action.WorktreeBranchPair], state: inout State
  ) {
    let cached = state.snapshotsByProject[projectID]
    for pair in pairs {
      // A branch switch: the refused merge belonged to the old branch's Pull Request.
      if let merge = state.headMovedMerges[pair.worktreeID], merge.branch != pair.branch {
        clearHeadMoved(pair.worktreeID, state: &state)
      }
      guard let current = state.snapshots[pair.worktreeID],
        current.headRefName != pair.branch
      else { continue }
      state.snapshots[pair.worktreeID] = cached?.byBranch[pair.branch]
    }
  }

  /// TTL for in-memory freshness. Under this window, repeat `projectActivated`
  /// dispatches for the same Project skip the fetch. Beyond it (including any
  /// disk-seeded cache from a prior launch — its `fetchedAt` is hours to days old),
  /// we always re-fetch so the user's second paint reflects whatever changed on
  /// the Git Platform's side since the cache was written. The cached snapshot is still used
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

  private func probeAvailabilityEffect(invalidatingFirst: Bool = false) -> Effect<Action> {
    .run { [gitPlatform] send in
      if invalidatingFirst { await gitPlatform.invalidateResolution() }
      var result: [GitPlatformKind: GitPlatformAvailability] = [:]
      for kind in GitPlatformKind.allCases {
        result[kind] = await gitPlatform.availability(kind)
      }
      await send(.availabilityProbed(result, probedAt: now))
    }
    .cancellable(id: CancelID.availabilityRefresh, cancelInFlight: true)
  }

  /// Runs one write action for a Worktree under its single mutation slot. A second
  /// request while one runs is dropped, so repeated clicks cannot race.
  private func mutationEffect(
    worktreeID: WorktreeID,
    state: inout State,
    operation: @escaping @Sendable () async throws -> Void,
    completed: @escaping @Sendable (TaskResult<Action.VoidSuccess>) -> Action
  ) -> Effect<Action> {
    if state.mutating.contains(worktreeID) { return .none }
    state.mutating.insert(worktreeID)
    return .run { send in
      let result = await TaskResult<Action.VoidSuccess> {
        try await operation()
        return Action.VoidSuccess()
      }
      await send(completed(result))
    }
    .cancellable(id: CancelID.mutation(worktreeID), cancelInFlight: true)
  }

  /// Forgets the refused merge of `worktreeID` and its `.headMoved` error.
  private static func clearHeadMoved(_ worktreeID: WorktreeID, state: inout State) {
    state.headMovedMerges[worktreeID] = nil
    if state.lastError[worktreeID] == .headMoved { state.lastError[worktreeID] = nil }
  }

  /// Fetches the unit that owns `worktreeID` now. `.none` when the Worktree has not been
  /// part of a batched fetch yet.
  private func refreshUnit(of worktreeID: WorktreeID, state: inout State) -> Effect<Action> {
    guard let projectID = state.projectByWorktree[worktreeID],
      let gitRoot = state.projectGitRoots[projectID],
      let pairs = state.projectWorktreePairs[projectID]
    else { return .none }
    return enqueueProjectFetch(projectID: projectID, gitRoot: gitRoot, pairs: pairs, state: &state)
  }

  private static func gitPlatformError(_ error: any Error) -> GitPlatformError {
    (error as? GitPlatformError) ?? .other(String(describing: error))
  }

  /// Re-fetches the owning Project after a mutation (merge / close / markReady / rerun)
  /// so every affected row in the repo reflects the new server state with a full check
  /// rollup — not the empty-checks single-branch v1 result. Resolves the Project from
  /// `projectByWorktree`; if the Worktree has not been part of a batched fetch yet,
  /// returns `.none` (the next `projectActivated` / poll tick will cover it). Delayed 2 s
  /// so the Git Platform has settled the write before we read it back.
  private func postMutationRefresh(
    worktreeID: WorktreeID, state: inout State
  ) -> Effect<Action> {
    guard let projectID = state.projectByWorktree[worktreeID] else { return .none }
    return scheduleDelayedRefresh(projectID)
  }

  /// Fetches the unit 2 s from now, so the Git Platform has settled a write before it is read
  /// back. A second request within the window restarts it.
  private func scheduleDelayedRefresh(_ projectID: ProjectID) -> Effect<Action> {
    .run { [clock] send in
      try await clock.sleep(for: .seconds(2))
      await send(.delayedProjectRefreshFired(projectID))
    }
    .cancellable(id: CancelID.delayedProjectRefresh(projectID), cancelInFlight: true)
  }

}

extension TaskResult where Success == GitPlatformFeature.Action.VoidSuccess {
  /// Convenience to keep the reducer's action construction terse.
  static var successVoid: TaskResult<GitPlatformFeature.Action.VoidSuccess> {
    .success(.init())
  }
}
