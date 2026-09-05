import ComposableArchitecture
import Foundation
import CodansCore
import os.log

/// Cached per-Worktree "is working tree dirty?" observer. The sidebar reads `isDirty`
/// keyed by `WorktreeID` to render a small pending-work dot next to the row.
///
/// - Fetches run lazily: the sidebar row's `.task(id:)` calls `refresh(worktreeID:path:)`
///   on appearance, branch change, or path change. A 30 s freshness window collapses
///   redundant re-fetches from hover churn / list re-renders.
/// - Failures are silent: a missing `.git` dir or a git-index lock returns the last
///   cached value (if any) and leaves `isDirty[id]` unchanged. The sidebar has no good
///   surface for per-row git errors, and a stale dot is less harmful than a wrong one.
/// - Lives in `Runtime/` next to `HierarchyManager` — same pattern: a
///   small observable service injected via `@Environment`, not TCA reducer state.
@Observable
@MainActor
final class WorktreeStatusMonitor {
  /// `true` when the most recent `git status` for the Worktree reported at least one
  /// entry (modified / added / deleted / untracked). `false` when the tree is clean.
  /// Missing key means "not yet fetched" — sidebar treats that the same as "clean".
  private(set) var isDirty: [WorktreeID: Bool] = [:]

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
  private var fetch: @Sendable (URL) async throws -> WorkingTreeStatus

  @ObservationIgnored
  private static let freshness: TimeInterval = 30

  private static let logger = Logger(subsystem: "com.gumpw.codans.sidebar", category: "status")

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
    isDirty = isDirty.filter { liveWorktreeIDs.contains($0.key) }
    lastFetchedAt = lastFetchedAt.filter { liveWorktreeIDs.contains($0.key) }
  }

  init(fetch: @escaping @Sendable (URL) async throws -> WorkingTreeStatus) {
    self.fetch = fetch
  }

  /// Convenience for production callers that want the live `GitServiceClient` closure.
  static func live() -> WorktreeStatusMonitor {
    let client = GitServiceClient.live()
    return WorktreeStatusMonitor(fetch: client.status)
  }

  /// Swap the fetch closure after construction. `AppState.init` builds the
  /// monitor before the `HierarchyManager` exists; `bringUp` calls this once
  /// with the SSH-routing `GitServiceClient` so Server-project worktrees get
  /// a live dirty flag too. Cached flags are untouched.
  func rebindFetch(_ fetch: @escaping @Sendable (URL) async throws -> WorkingTreeStatus) {
    self.fetch = fetch
  }

  /// Refreshes the dirty flag for the given Worktree, honouring the 30 s freshness
  /// window. Re-entrant calls while a fetch is in flight are deduped. Safe to call on
  /// every `.task(id:)` — the view is in charge of re-invoking when the worktree path
  /// or branch changes.
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
    let fetched: WorkingTreeStatus?
    do {
      fetched = try await fetch(path)
    } catch {
      fetched = nil
      Self.logger.debug(
        "status fetch failed for \(path.path, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .public)"
      )
    }
    inFlight.remove(worktreeID)
    let wasEvicted = evictedWhileInFlight.remove(worktreeID) != nil
    let queued = pendingRefresh.removeValue(forKey: worktreeID)
    if let fetched, !wasEvicted {
      isDirty[worktreeID] = !fetched.isClean
      lastFetchedAt[worktreeID] = Date()
    }
    // This run was discarded, so a request that arrived while it was in
    // flight has nothing to show for it. Serve it now: the caller's
    // `.task(id:)` has already fired and will not retry on its own.
    if wasEvicted, let queued {
      await refresh(worktreeID: worktreeID, path: queued)
    }
  }
}
