import Foundation
import CodansCore
import os.log

/// Persists the Git Platform layer's per-fetch-unit Pull Request snapshots to disk so the
/// sidebar can paint badges on the first render pass after launch, before any Git Platform
/// round-trip has completed. The reducer state is hydrated from this cache on
/// `GitPlatformFeature.Action.seedFromCache`, and written back on every
/// `projectBatchLoaded(.success)`.
///
/// On-disk shape: one JSON file at `~/Library/Caches/codans/github-snapshots.json` (the
/// name predates the Git Platform layer; keeping it avoids an orphaned file), a
/// `VersionedEnvelope` whose entries map fetch-unit UUID strings to
/// `BatchedPullRequests`. An unreadable file is deleted, and an entry that does not
/// decode with the current model is dropped — the next fetch refills it. There is no
/// migration. Stale Projects (no longer in the catalog) are dropped by
/// `GitPlatformFeature` when it seeds from the cache.
///
/// Writes atomic via `AtomicFileStore.write`; a crash mid-write leaves the previous
/// file intact. Failures are logged and swallowed — a stale cache is a UX
/// degradation, not a correctness issue.
nonisolated final class PullRequestSnapshotCache: Sendable {
  private let fileURL: URL
  private let writeLock = NSLock()
  /// Highest `sequence` committed to disk. Guarded by `writeLock`.
  private nonisolated(unsafe) var lastWrittenSequence: UInt64 = 0
  private static let logger = Logger(
    subsystem: "com.gumpw.codans.gitplatform", category: "snapshot-cache"
  )

  /// Envelope version. v0 (unversioned, keyed by `ProjectID` objects) is dropped whole.
  /// v1 held GitHub wire values and an owner/repo pair; its entries no longer decode and
  /// are dropped one by one.
  static let currentVersion = 2

  init(fileURL: URL = PullRequestSnapshotCache.defaultURL()) {
    self.fileURL = fileURL
  }

  /// Standard on-disk location: `AppDirectories.cacheDirectory`
  /// (`~/Library/Caches/codans[-dev]/`) — the file is a refetchable cache, so
  /// it lives where the system may purge it. Parent directory creation is
  /// `AtomicFileStore`'s job.
  static func defaultURL() -> URL {
    AppDirectories.cacheDirectory()
      .appendingPathComponent("github-snapshots.json", isDirectory: false)
  }

  /// Returns the cached snapshot map, or `[:]` on missing / unreadable file. Never throws.
  func load() -> [ProjectID: BatchedPullRequests] {
    let result = VersionedFile.load(
      [String: LossyEntry].self, at: fileURL, currentVersion: Self.currentVersion,
      empty: [:], unreadable: .discard
    )
    guard case .loaded(let entries) = result else {
      Self.logger.error("snapshot-cache load failed: unreadable file could not be removed")
      return [:]
    }
    var map: [ProjectID: BatchedPullRequests] = [:]
    for (key, entry) in entries {
      guard let uuid = UUID(uuidString: key), let value = entry.value else { continue }
      map[ProjectID(raw: uuid)] = value
    }
    if map.count != entries.count {
      Self.logger.info(
        "snapshot-cache dropped \(entries.count - map.count, privacy: .public) undecodable entr(y/ies)"
      )
    }
    return map
  }

  /// One cache entry that decodes to `nil` instead of failing the whole file, so one
  /// entry in an older shape does not take the other entries with it.
  private struct LossyEntry: Codable, Sendable {
    let value: BatchedPullRequests?

    init(from decoder: Decoder) throws {
      value = try? BatchedPullRequests(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
      try value.encode(to: encoder)
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
      let entries = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.raw.uuidString, $0.value) })
      try VersionedFile.write(entries, to: fileURL, version: Self.currentVersion)
      lastWrittenSequence = sequence
    } catch {
      Self.logger.error(
        "snapshot-cache save failed: \(String(describing: error), privacy: .public)"
      )
    }
  }
}
