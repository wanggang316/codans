import CodansCore
import ComposableArchitecture
import CoreServices
import Foundation

/// Per-Worktree FSEvents observer on the working-tree root subtree. Fires
/// `events()` whenever a file under `<worktree>` (excluding `.git/`) is
/// created / modified / removed so the sidebar's `+N −M` chip — backed by
/// `WorktreeLocalDiffMonitor` — refreshes after edits made in a pane /
/// editor, not just on commit or row remount.
///
/// `.git/` writes (index / logs / `HEAD.lock` → `HEAD`) are filtered out:
/// HEAD-driven refresh is owned by `WorktreeHeadWatcher`, and `git`'s own
/// index churn would otherwise loop us. Stream lifecycle lives in
/// `FSEventsTreeWatcher`.
@MainActor
final class WorktreeWorkingTreeWatcher {
  private let core: FSEventsTreeWatcher<WorktreeID>

  init(
    debounceInterval: Duration = .milliseconds(500),
    latency: CFTimeInterval = 0.2,
    streamStarter: @escaping @Sendable (FSEventStreamRef) -> Bool = {
      FSEventStreamStart($0)
    }
  ) {
    core = FSEventsTreeWatcher(
      label: "codans.worktree-fswatch",
      debounceInterval: debounceInterval,
      latency: latency,
      accepts: { path in !path.contains("/.git/") && !path.hasSuffix("/.git") },
      streamStarter: streamStarter)
  }

  /// Test observability: how many registered streams have been discarded.
  var discardedStreamCount: Int { core.discardedStreamCount }

  /// Single subscriber. RootFeature's `onLaunch` is the only caller.
  func events() -> AsyncStream<WorktreeID> { core.events() }

  /// Sync the set of watched worktrees against the catalog.
  func setWorktrees(_ worktrees: [(id: WorktreeID, path: String)]) {
    core.setRoots(Dictionary(uniqueKeysWithValues: worktrees.map { ($0.id, $0.path) }))
  }

  func isWatching(_ worktreeID: WorktreeID, path: String) -> Bool {
    core.isWatching(worktreeID, path: path)
  }

  /// Tear everything down. Called from the host app's `onQuit` path.
  func stopAll() { core.stopAll() }
}

extension WorktreeWorkingTreeWatcher: DependencyKey {
  /// Unconfigured fallback until `CodansApp.bringUp` overrides it with the
  /// live instance. Mirrors `WorktreeHeadWatcher.liveValue`: a real instance
  /// whose `setWorktrees` is never called, so no streams attach and `events()`
  /// finishes immediately — lets reducer wiring resolve the dependency in
  /// tests without an explicit override.
  static var liveValue: WorktreeWorkingTreeWatcher {
    MainActor.assumeIsolated { WorktreeWorkingTreeWatcher() }
  }

  static var testValue: WorktreeWorkingTreeWatcher { liveValue }
}

extension DependencyValues {
  var worktreeWorkingTreeWatcher: WorktreeWorkingTreeWatcher {
    get { self[WorktreeWorkingTreeWatcher.self] }
    set { self[WorktreeWorkingTreeWatcher.self] = newValue }
  }
}
