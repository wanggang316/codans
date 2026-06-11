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

  @ObservationIgnored
  private let fetch: @Sendable (URL) async throws -> LocalDiffStats?

  @ObservationIgnored
  private static let freshness: TimeInterval = 5

  private static let logger = Logger(subsystem: "com.gumpw.codans.sidebar", category: "localDiff")

  init(fetch: @escaping @Sendable (URL) async throws -> LocalDiffStats?) {
    self.fetch = fetch
  }

  static func live() -> WorktreeLocalDiffMonitor {
    let client = GitServiceClient.live()
    return WorktreeLocalDiffMonitor(fetch: client.localDiffStats)
  }

  /// Refreshes the local diff stats for the given Worktree, honouring the
  /// freshness window. Re-entrant calls while a fetch is in flight are
  /// deduped. Safe to call on every `.task(id:)`.
  func refresh(worktreeID: WorktreeID, path: URL) async {
    if inFlight.contains(worktreeID) { return }
    if let fetchedAt = lastFetchedAt[worktreeID],
      Date().timeIntervalSince(fetchedAt) < Self.freshness
    {
      return
    }
    inFlight.insert(worktreeID)
    defer { inFlight.remove(worktreeID) }
    do {
      let result = try await fetch(path)
      stats[worktreeID] = result
      lastFetchedAt[worktreeID] = Date()
    } catch {
      Self.logger.debug(
        "local-diff fetch failed for \(path.path, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .public)"
      )
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
