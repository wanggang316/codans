import CodansCore
import CoreServices
import Foundation
import Testing

@testable import Codans

/// Pins the off-main-actor contract of `WorktreeWorkingTreeWatcher`.
///
/// `FSEventStreamStart` performs a synchronous registration RPC against
/// fseventsd (`register_with_server`), which on a busy machine blocks for
/// seconds per stream — measured locally with 16 agents churning worktrees:
/// 17 sequential starts ≈ 39 s. The watcher used to run that loop on the
/// main actor at launch, freezing the UI for the whole window. The first
/// test injects a start that blocks on a semaphore (an idle CI machine
/// can't reproduce the real-world latency) and asserts `setWorktrees`
/// returns while the registration is still parked, then confirms the
/// stream delivers once it goes through. The second pins the claim
/// bookkeeping under A → B re-pointing.
@MainActor
struct WorktreeWorkingTreeWatcherTests {
  @Test
  func setWorktreesReturnsWhileRegistrationIsStillBlocked() async throws {
    let dir = try Self.makeTempDir()

    let id = WorktreeID(raw: UUID())
    let gate = StartGate()
    let watcher = WorktreeWorkingTreeWatcher(streamStarter: gate.start)
    let events = watcher.events()
    var iterator = events.makeAsyncIterator()
    let received = Handoff<WorktreeID>()
    let collector = Task { received.value = await iterator.next() }
    defer {
      collector.cancel()
      watcher.stopAll()
      try? FileManager.default.removeItem(at: dir)
    }

    let t0 = Date()
    watcher.setWorktrees([(id: id, path: dir.path)])
    let callMS = Int(Date().timeIntervalSince(t0) * 1000)
    #expect(callMS < 500, "setWorktrees blocked the caller for \(callMS) ms")

    // The registration must be running (and parked) off the caller, and
    // the caller must have returned before it could possibly finish.
    try await Self.waitUntil { gate.isEntered }
    #expect(!gate.hasFinished, "start already finished — nothing was proven")

    gate.open()
    let file = dir.appendingPathComponent("nudge.txt")
    var landed = false
    for _ in 0..<60 {
      try? "\(Date())".write(to: file, atomically: true, encoding: .utf8)
      if received.value != nil { landed = true; break }
      try? await Task.sleep(for: .milliseconds(250))
    }
    #expect(landed, "no working-tree event after the start was released")
    #expect(received.value == id)
  }

  @Test
  func rePointingAWorktreeSupersedesTheInFlightStartForTheOldPath() async throws {
    let oldDir = try Self.makeTempDir()
    let newDir = try Self.makeTempDir()

    let id = WorktreeID(raw: UUID())
    let watcher = WorktreeWorkingTreeWatcher()
    let events = watcher.events()
    var iterator = events.makeAsyncIterator()
    let received = Handoff<WorktreeID>()
    let collector = Task { received.value = await iterator.next() }
    defer {
      collector.cancel()
      watcher.stopAll()
      try? FileManager.default.removeItem(at: oldDir)
      try? FileManager.default.removeItem(at: newDir)
    }

    // Back-to-back with no await between: the second claim must supersede
    // the first whether or not the old start already completed on the
    // register queue. (With the old unconditional claim removal, BOTH
    // starts tore themselves down here and the worktree went unwatched.)
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

  private static func waitUntil(
    _ condition: @autoclosure @Sendable () -> Bool,
    timeout: Duration = .seconds(5)
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      if ContinuousClock.now > deadline {
        Issue.record("condition not met within \(timeout)")
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  /// Holds a registration open: `start` parks on a semaphore before the
  /// real `FSEventStreamStart`, so a test can prove the caller of
  /// `setWorktrees` is not waiting on it.
  private final class StartGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let state = NSLock()
    private var enteredFlag = false
    private var finishedFlag = false

    var isEntered: Bool {
      state.lock(); defer { state.unlock() }
      return enteredFlag
    }

    var hasFinished: Bool {
      state.lock(); defer { state.unlock() }
      return finishedFlag
    }

    func open() {
      semaphore.signal()
    }

    var start: @Sendable (FSEventStreamRef) -> Bool {
      { stream in
        state.lock(); enteredFlag = true; state.unlock()
        semaphore.wait()
        let ok = FSEventStreamStart(stream)
        state.lock(); finishedFlag = true; state.unlock()
        return ok
      }
    }
  }

  /// Mutable box shared with the collector task. `@unchecked Sendable`
  /// mirrors the `CallCounter` / `Gate` pattern in `WorktreeMonitorRetainTests`:
  /// a single writer (the collector) and a main-actor reader.
  private final class Handoff<T>: @unchecked Sendable {
    var value: T?
  }
}
