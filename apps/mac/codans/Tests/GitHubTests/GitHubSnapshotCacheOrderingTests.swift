import Foundation
import Testing

@testable import Codans
@testable import CodansCore

/// The reducer starts its cache writes in detached tasks, so two can be in
/// flight at once — a batch completion and a prune. `AtomicFileStore` only
/// guarantees each write lands whole, not that the newer one wins, so an
/// older save finishing last would put pruned Projects back on disk.
struct GitHubSnapshotCacheOrderingTests {
  @Test
  func aStaleSaveCannotOverwriteANewerOne() throws {
    let url = Self.tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = GitHubSnapshotCache(fileURL: url)
    let live = ProjectID()
    let dead = ProjectID()

    // The prune's write commits first.
    cache.save([live: Self.batched("main")], sequence: 2)
    // The batch completion started earlier and lands after it, still holding
    // the removed Project.
    cache.save([live: Self.batched("main"), dead: Self.batched("old")], sequence: 1)

    let onDisk = cache.load()
    #expect(onDisk.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) == [live])
    #expect(onDisk[dead] == nil)
  }

  @Test
  func anewerSaveStillWins() throws {
    let url = Self.tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = GitHubSnapshotCache(fileURL: url)
    let live = ProjectID()
    let dead = ProjectID()

    cache.save([live: Self.batched("main"), dead: Self.batched("old")], sequence: 1)
    cache.save([live: Self.batched("main")], sequence: 2)

    #expect(cache.load()[dead] == nil)
  }

  @Test
  func concurrentSavesLeaveTheHighestSequenceOnDisk() async throws {
    let url = Self.tempURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let cache = GitHubSnapshotCache(fileURL: url)
    let live = ProjectID()
    let dead = ProjectID()
    let stale = [live: Self.batched("main"), dead: Self.batched("old")]
    let pruned = [live: Self.batched("main")]

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask { cache.save(stale, sequence: 1) }
        group.addTask { cache.save(pruned, sequence: 2) }
      }
    }

    #expect(cache.load()[dead] == nil)
  }

  private static func batched(_ branch: String) -> BatchedPullRequests {
    BatchedPullRequests(
      host: "github.com", owner: "w", repo: "r",
      byBranch: [:], seenBranches: [branch], fetchedAt: Date(timeIntervalSince1970: 1)
    )
  }

  private static func tempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("codans-snapshot-cache-\(UUID().uuidString).json")
  }
}
