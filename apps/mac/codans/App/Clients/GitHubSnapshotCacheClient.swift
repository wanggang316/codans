import ComposableArchitecture
import Foundation
import CodansCore

/// TCA-side bridge over `GitHubSnapshotCache`. The reducer reads on seed and writes
/// after every successful `projectBatchLoaded` so the next relaunch paints the
/// sidebar from disk before any `gh` round-trip returns.
nonisolated struct GitHubSnapshotCacheClient: Sendable {
  var load: @Sendable () -> [ProjectID: BatchedPullRequests]
  var save: @Sendable ([ProjectID: BatchedPullRequests], UInt64) -> Void
}

extension GitHubSnapshotCacheClient: DependencyKey {
  static let liveValue: GitHubSnapshotCacheClient = {
    let cache = GitHubSnapshotCache()
    return GitHubSnapshotCacheClient(
      load: { cache.load() },
      save: { cache.save($0, sequence: $1) }
    )
  }()

  static let testValue = GitHubSnapshotCacheClient(
    load: { [:] },
    save: { _, _ in }
  )
}

extension DependencyValues {
  var gitHubSnapshotCache: GitHubSnapshotCacheClient {
    get { self[GitHubSnapshotCacheClient.self] }
    set { self[GitHubSnapshotCacheClient.self] = newValue }
  }
}
