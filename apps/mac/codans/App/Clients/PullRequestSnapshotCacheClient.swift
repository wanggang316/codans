import CodansCore
import ComposableArchitecture
import Foundation

/// TCA-side bridge over `PullRequestSnapshotCache`. The reducer reads on seed and writes
/// after every successful `projectBatchLoaded` so the next relaunch paints the sidebar
/// from disk before any Code Host round-trip returns.
nonisolated struct PullRequestSnapshotCacheClient: Sendable {
  var load: @Sendable () -> [ProjectID: BatchedPullRequests]
  var save: @Sendable ([ProjectID: BatchedPullRequests], UInt64) -> Void
}

extension PullRequestSnapshotCacheClient: DependencyKey {
  static let liveValue: PullRequestSnapshotCacheClient = {
    let cache = PullRequestSnapshotCache()
    return PullRequestSnapshotCacheClient(
      load: { cache.load() },
      save: { cache.save($0, sequence: $1) }
    )
  }()

  static let testValue = PullRequestSnapshotCacheClient(
    load: { [:] },
    save: { _, _ in }
  )
}

extension DependencyValues {
  var pullRequestSnapshotCache: PullRequestSnapshotCacheClient {
    get { self[PullRequestSnapshotCacheClient.self] }
    set { self[PullRequestSnapshotCacheClient.self] = newValue }
  }
}
