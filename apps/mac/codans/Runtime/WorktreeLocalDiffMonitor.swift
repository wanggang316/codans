import ComposableArchitecture
import Foundation
import CodansCore
import os.log

/// Cached per-Worktree "uncommitted edits" line-count observer
/// (`git diff HEAD --shortstat`). Drives the `+N −M` chip on every sidebar
/// worktree row, including rows with no PR matched.
///
/// Refresh triggers:
/// - Lazy on row appearance: `HierarchySidebarView.worktreeRow`'s
///   `.task(id: worktree.path)` calls `refresh(worktreeID:path:)`. A short
///   freshness window (`freshness`) collapses redundant rerenders into a
///   single fetch.
/// - HEAD events: `RootFeature.worktreeHeadChanged` calls `invalidate(_:)`
///   then `refresh(...)` so a commit / branch-switch in a terminal pane
///   updates the chip in the same tick the head watcher fires, instead of
///   waiting for the row to remount.
///
/// Failures are silent. A non-repo, unborn HEAD, or transient git error
/// returns the last cached value (if any) and leaves `stats[id]` unchanged
/// — a stale chip is less harmful than a wrong one.
@Observable
@MainActor
final class WorktreeLocalDiffMonitor {
  /// Latest stats per worktree. `nil` value = "fetched, no stats available"
  /// (unborn HEAD / git error during initial fetch); missing key = "not yet
  /// fetched". Both render as "nothing" at the call site.
  private(set) var stats: [WorktreeID: LocalDiffStats?] = [:]

  @ObservationIgnored
  private var lastFetchedAt: [WorktreeID: Date] = [:]

  @ObservationIgnored
  private var inFlight: Set<WorktreeID> = []

  /// Worktrees evicted by `retain` while a fetch for them was still awaiting.
  /// Their result must be discarded: writing it back would resurrect the
  /// entry `retain` just dropped, and would stamp a fresh `lastFetchedAt`
  /// that blocks a real refresh for the whole freshness window if the
  /// Worktree comes back.
  @ObservationIgnored
  private var evictedWhileInFlight: Set<WorktreeID> = []

  /// Refresh requests that arrived while another was in flight for the same
  /// Worktree, keyed by the path they asked for. Replayed only when the
  /// in-flight run's result is discarded — otherwise that result already
  /// answers them.
  @ObservationIgnored
  private var pendingRefresh: [WorktreeID: URL] = [:]

  @ObservationIgnored
  private var fetch: @Sendable (URL) async throws -> LocalDiffStats?

  @ObservationIgnored
  private static let freshness: TimeInterval = 5

  private static let logger = Logger(subsystem: "com.gumpw.codans.sidebar", category: "localDiff")

  /// Drop every cached entry for a Worktree the catalog no longer shows.
  ///
  /// Entries are created lazily by the sidebar row's `.task` and had no
  /// removal path at all, so a Worktree that was removed or archived kept
  /// its cached value for the life of the process. Driven by the same
  /// catalog-observation pump that keeps the HEAD watcher in sync, which
  /// already projects exactly this set.
  func retain(liveWorktreeIDs: Set<WorktreeID>) {
    evictedWhileInFlight.formUnion(inFlight.subtracting(liveWorktreeIDs))
    // Queued requests from before the eviction die with it. Replaying one
    // would re-fetch and re-cache a Worktree that is gone — the replay path
    // exists for a Worktree that came back and asked again, which can only
    // be a request recorded after this point.
    pendingRefresh = pendingRefresh.filter { liveWorktreeIDs.contains($0.key) }
    stats = stats.filter { liveWorktreeIDs.contains($0.key) }
    lastFetchedAt = lastFetchedAt.filter { liveWorktreeIDs.contains($0.key) }
  }

  init(fetch: @escaping @Sendable (URL) async throws -> LocalDiffStats?) {
    self.fetch = fetch
  }

  static func live() -> WorktreeLocalDiffMonitor {
    let client = GitServiceClient.live()
    return WorktreeLocalDiffMonitor(fetch: client.localDiffStats)
  }

  /// Swap the fetch closure after construction. `AppState.init` builds the
  /// monitor before the `HierarchyManager` exists; `bringUp` calls this once
  /// with the SSH-routing `GitServiceClient` so Server-project worktrees get
  /// their `+N −M` chip too. Cached stats are untouched — only future
  /// fetches use the new closure.
  func rebindFetch(_ fetch: @escaping @Sendable (URL) async throws -> LocalDiffStats?) {
    self.fetch = fetch
  }

  /// Refreshes the local diff stats for the given Worktree, honouring the
  /// freshness window. Re-entrant calls while a fetch is in flight are
  /// deduped. Safe to call on every `.task(id:)`.
  func refresh(worktreeID: WorktreeID, path: URL) async {
    if inFlight.contains(worktreeID) {
      // Remember it. If the running request's result is discarded by
      // `retain`, nothing else re-drives this Worktree.
      pendingRefresh[worktreeID] = path
      return
    }
    if let fetchedAt = lastFetchedAt[worktreeID],
      Date().timeIntervalSince(fetchedAt) < Self.freshness
    {
      return
    }
    inFlight.insert(worktreeID)
    let fetched: LocalDiffStats??
    do {
      fetched = try await fetch(path)
    } catch {
      fetched = nil
      Self.logger.debug(
        "local-diff fetch failed for \(path.path, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .public)"
      )
    }
    inFlight.remove(worktreeID)
    let wasEvicted = evictedWhileInFlight.remove(worktreeID) != nil
    let queued = pendingRefresh.removeValue(forKey: worktreeID)
    if let fetched, !wasEvicted {
      stats[worktreeID] = fetched
      lastFetchedAt[worktreeID] = Date()
    }
    // This run was discarded, so a request that arrived while it was in
    // flight has nothing to show for it. Serve it now: the caller's
    // `.task(id:)` has already fired and will not retry on its own.
    if wasEvicted, let queued {
      await refresh(worktreeID: worktreeID, path: queued)
    }
  }

  /// Drop the cached freshness timestamp for `worktreeID` so the next
  /// `refresh` call bypasses the freshness window. Used by HEAD-watcher
  /// events: a commit changes HEAD, so the existing "+N −M" against HEAD is
  /// stale by definition — we want the next fetch to actually fire.
  func invalidate(worktreeID: WorktreeID) {
    lastFetchedAt.removeValue(forKey: worktreeID)
  }
}

extension WorktreeLocalDiffMonitor: DependencyKey {
  /// Created once per app process via `liveValue` so reducer dependencies
  /// resolve to the same instance the views observe via `@Environment`.
  /// `MainActor.assumeIsolated` mirrors `WorktreeHeadWatcher.liveValue`.
  static var liveValue: WorktreeLocalDiffMonitor {
    MainActor.assumeIsolated { .live() }
  }
  /// Tests get the same shared instance; if a test needs isolation it
  /// supplies its own via `withDependencies`.
  static var testValue: WorktreeLocalDiffMonitor { liveValue }
}

extension DependencyValues {
  var worktreeLocalDiffMonitor: WorktreeLocalDiffMonitor {
    get { self[WorktreeLocalDiffMonitor.self] }
    set { self[WorktreeLocalDiffMonitor.self] = newValue }
  }
}
