import Foundation
import TouchCodeCore
import os.log

/// Persists the GitHub integration's per-Project PR snapshots to disk so the sidebar
/// can paint badges on the first render pass after launch, before any `gh api graphql`
/// round-trip has completed. The in-memory-only v2 reducer state is hydrated from this
/// cache on `GitHubFeature.Action.seedFromCache`, and written back on every
/// `projectBatchLoaded(.success)`.
///
/// On-disk shape: one JSON file at `~/.config/touch-code/github-snapshots.json`
/// encoding `[ProjectID: BatchedPullRequests]`. Stale Projects (no longer in the
/// catalog) are harmless — they sit unused in the map and get garbage-collected on
/// the next app launch by `GitHubFeature` if it prunes by current Worktree list.
///
/// Writes atomic via `AtomicFileStore.write`; a crash mid-write leaves the previous
/// file intact. Failures are logged and swallowed — a stale cache is a UX
/// degradation, not a correctness issue.
nonisolated final class GitHubSnapshotCache: Sendable {
  private let fileURL: URL
  private static let logger = Logger(
    subsystem: "com.touch-code.github", category: "snapshot-cache"
  )

  init(fileURL: URL = GitHubSnapshotCache.defaultURL()) {
    self.fileURL = fileURL
  }

  /// Standard on-disk location: sibling of `catalog.json` under
  /// `AppDirectories.configDirectory` (`~/.config/touch-code[-dev]/`). Parent
  /// directory creation is `AtomicFileStore`'s job.
  static func defaultURL(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    AppDirectories.configDirectory(home: home)
      .appendingPathComponent("github-snapshots.json", isDirectory: false)
  }

  /// Returns the cached snapshot map, or `[:]` on missing / corrupt file. Never throws.
  func load() -> [ProjectID: BatchedPullRequests] {
    do {
      if let map = try AtomicFileStore.read([ProjectID: BatchedPullRequests].self, at: fileURL) {
        return map
      }
      return [:]
    } catch {
      Self.logger.error(
        "snapshot-cache load failed: \(String(describing: error), privacy: .public)"
      )
      return [:]
    }
  }

  /// Writes atomically. Swallows errors with a log line — the cache is best-effort.
  func save(_ snapshots: [ProjectID: BatchedPullRequests]) {
    do {
      try AtomicFileStore.write(snapshots, to: fileURL)
    } catch {
      Self.logger.error(
        "snapshot-cache save failed: \(String(describing: error), privacy: .public)"
      )
    }
  }
}
