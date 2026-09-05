import Foundation
import CodansCore
import os.log

/// Persists the GitHub integration's per-Project PR snapshots to disk so the sidebar
/// can paint badges on the first render pass after launch, before any `gh api graphql`
/// round-trip has completed. The in-memory-only v2 reducer state is hydrated from this
/// cache on `GitHubFeature.Action.seedFromCache`, and written back on every
/// `projectBatchLoaded(.success)`.
///
/// On-disk shape: one JSON file at `~/.config/codans/github-snapshots.json`
/// encoding `[ProjectID: BatchedPullRequests]`. Stale Projects (no longer in the
/// catalog) are harmless — they sit unused in the map and get garbage-collected on
/// the next app launch by `GitHubFeature` if it prunes by current Worktree list.
///
/// Writes atomic via `AtomicFileStore.write`; a crash mid-write leaves the previous
/// file intact. Failures are logged and swallowed — a stale cache is a UX
/// degradation, not a correctness issue.
nonisolated final class GitHubSnapshotCache: Sendable {
  private let fileURL: URL
  private let writeLock = NSLock()
  /// Highest `sequence` committed to disk. Guarded by `writeLock`.
  private nonisolated(unsafe) var lastWrittenSequence: UInt64 = 0
  private static let logger = Logger(
    subsystem: "com.gumpw.codans.github", category: "snapshot-cache"
  )

  init(fileURL: URL = GitHubSnapshotCache.defaultURL()) {
    self.fileURL = fileURL
  }

  /// Standard on-disk location: sibling of `catalog.json` under
  /// `AppDirectories.configDirectory` (`~/.config/codans[-dev]/`). Parent
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
  ///
  /// `sequence` orders concurrent writers. Two detached saves can be in
  /// flight at once — a batch completion and a prune — and `AtomicFileStore`
  /// only guarantees each write lands whole, not that the newer one wins. A
  /// batch save that started before a prune and finished after it would put
  /// the pruned Projects straight back on disk. Writes carrying a sequence
  /// no newer than the last one committed are dropped, and the lock keeps
  /// the compare and the write from interleaving.
  func save(_ snapshots: [ProjectID: BatchedPullRequests], sequence: UInt64) {
    writeLock.lock()
    defer { writeLock.unlock() }
    guard sequence > lastWrittenSequence else {
      Self.logger.info(
        "snapshot-cache save skipped: sequence \(sequence, privacy: .public) is not newer than \(self.lastWrittenSequence, privacy: .public)"
      )
      return
    }
    do {
      try AtomicFileStore.write(snapshots, to: fileURL)
      lastWrittenSequence = sequence
    } catch {
      Self.logger.error(
        "snapshot-cache save failed: \(String(describing: error), privacy: .public)"
      )
    }
  }
}
