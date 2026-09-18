import CodansCore
import Foundation
import Testing

@testable import Codans

/// Pins the off-main-actor contract of `WorktreeWorkingTreeWatcher`.
///
/// `FSEventStreamStart` performs a synchronous registration RPC against
/// fseventsd (`register_with_server`), which on a busy machine blocks for
/// seconds per stream — measured locally with 16 agents churning worktrees:
/// 17 sequential starts ≈ 39 s. The watcher used to run that loop on the
/// main actor at launch, freezing the UI for the whole window. These tests
/// hold the two halves of the fix: `setWorktrees` returns immediately
/// (dictionary work + a dispatch, never a daemon round-trip), and a
/// started stream still delivers debounced events for its worktree.
@MainActor
struct WorktreeWorkingTreeWatcherTests {
  @Test
  func setWorktreesDoesNotBlockAndDeliversEventsForTheWatchedTree() async throws {
    let dir = try Self.makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let id = WorktreeID(raw: UUID())
    let watcher = WorktreeWorkingTreeWatcher()
    let events = watcher.events()
    var iterator = events.makeAsyncIterator()
    let received = Handoff<WorktreeID>()
    let collector = Task { received.value = await iterator.next() }
    defer { collector.cancel() }

    let t0 = Date()
    watcher.setWorktrees([(id: id, path: dir.path)])
    let callMS = Int(Date().timeIntervalSince(t0) * 1000)
    #expect(callMS < 500, "setWorktrees blocked the caller for \(callMS) ms")

    // Registration + first delivery (FSEvents latency 0.2 s + debounce
    // 0.5 s) can legitimately take seconds on a contended fseventsd, so
    // keep nudging the tree until the event lands or the budget runs out.
    let file = dir.appendingPathComponent("nudge.txt")
    var landed = false
    for _ in 0..<60 {
      try? "\(Date())".write(to: file, atomically: true, encoding: .utf8)
      if received.value != nil { landed = true; break }
      try? await Task.sleep(for: .milliseconds(250))
    }
    #expect(landed, "no working-tree event within 15 s of watching \(dir.path)")
    #expect(received.value == id)
  }

  @Test
  func rePointingAWorktreeSupersedesTheInFlightStartForTheOldPath() async throws {
    let oldDir = try Self.makeTempDir()
    let newDir = try Self.makeTempDir()
    defer {
      try? FileManager.default.removeItem(at: oldDir)
      try? FileManager.default.removeItem(at: newDir)
    }

    let id = WorktreeID(raw: UUID())
    let watcher = WorktreeWorkingTreeWatcher()
    let events = watcher.events()
    var iterator = events.makeAsyncIterator()
    let received = Handoff<WorktreeID>()
    let collector = Task { received.value = await iterator.next() }
    defer { collector.cancel() }

    // Back-to-back with no await between: the second claim must supersede
    // the first whether or not the old start already completed on the queue.
    watcher.setWorktrees([(id: id, path: oldDir.path)])
    watcher.setWorktrees([(id: id, path: newDir.path)])

    let newFile = newDir.appendingPathComponent("nudge.txt")
    var landed = false
    for _ in 0..<60 {
      try? "\(Date())".write(to: newFile, atomically: true, encoding: .utf8)
      if received.value != nil { landed = true; break }
      try? await Task.sleep(for: .milliseconds(250))
    }
    #expect(landed, "the re-pointed path never produced an event")

    // The old path must be unwatched: whichever interleaving won, the
    // superseded stream was torn down instead of installed.
    received.value = nil
    let oldFile = oldDir.appendingPathComponent("stale.txt")
    var stale = false
    for _ in 0..<12 {
      try? "\(Date())".write(to: oldFile, atomically: true, encoding: .utf8)
      if received.value != nil { stale = true; break }
      try? await Task.sleep(for: .milliseconds(250))
    }
    #expect(!stale, "the superseded path still delivered an event")
  }

  // MARK: - Helpers

  private static func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("wtw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Mutable box shared with the collector task. `@unchecked Sendable`
  /// mirrors the `CallCounter` / `Gate` pattern in `WorktreeMonitorRetainTests`:
  /// a single writer (the collector) and a main-actor reader.
  private final class Handoff<T>: @unchecked Sendable {
    var value: T?
  }
}
