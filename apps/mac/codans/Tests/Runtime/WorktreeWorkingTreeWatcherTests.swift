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
/// main actor at launch, freezing the UI for the whole window.
///
/// Event delivery is deliberately NOT asserted here: the stream is created
/// with `IgnoreSelf`, so writes from this process never fire, and CI's
/// fseventsd latency varies wildly. The tests instead pin the two halves
/// that must hold regardless — `setWorktrees` returns while the (injected,
/// semaphore-gated) registration is still parked, and the install/supersede
/// claim bookkeeping lands the right stream in `isWatching`.
@MainActor
struct WorktreeWorkingTreeWatcherTests {
  @Test
  func setWorktreesReturnsWhileRegistrationIsStillBlocked() async throws {
    let dir = try Self.makeTempDir()
    let id = WorktreeID(raw: UUID())
    let gate = StartGate()
    let watcher = WorktreeWorkingTreeWatcher(streamStarter: gate.start)

    defer {
      // A failure before the assertions must not leave `registerQueue`
      // parked on the semaphore for the rest of the test run.
      gate.open()
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
    #expect(!watcher.isWatching(id, path: dir.path))

    // Release and let the install land.
    gate.open()
    try await Self.waitUntil { watcher.isWatching(id, path: dir.path) }
  }

  @Test
  func rePointingAWorktreeSupersedesTheInFlightStartForTheOldPath() async throws {
    let oldDir = try Self.makeTempDir()
    let newDir = try Self.makeTempDir()
    let id = WorktreeID(raw: UUID())
    let watcher = WorktreeWorkingTreeWatcher()

    defer {
      watcher.stopAll()
      try? FileManager.default.removeItem(at: oldDir)
      try? FileManager.default.removeItem(at: newDir)
    }

    // Back-to-back with no await between: the second claim must supersede
    // the first whether or not the old start already completed on the
    // register queue. (With the old unconditional claim removal, BOTH
    // starts tore themselves down and no stream ever installed.)
    watcher.setWorktrees([(id: id, path: oldDir.path)])
    watcher.setWorktrees([(id: id, path: newDir.path)])

    try await Self.waitUntil { watcher.isWatching(id, path: newDir.path) }
    #expect(!watcher.isWatching(id, path: oldDir.path))
  }

  // MARK: - Helpers

  private static func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("wtw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static func waitUntil(
    _ condition: @autoclosure @escaping () -> Bool,
    timeout: Duration = .seconds(15)
  ) async throws {
    let box = ConditionBox(condition)
    let deadline = ContinuousClock.now + timeout
    while !box.check() {
      if ContinuousClock.now > deadline {
        Issue.record("condition not met within \(timeout) seconds")
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

  /// The polling condition touches MainActor state and is only ever
  /// invoked from the (MainActor) `waitUntil` loop; the lock mirrors the
  /// `CallCounter` pattern in `WorktreeMonitorRetainTests`.
  private final class ConditionBox: @unchecked Sendable {
    private let condition: () -> Bool
    private let lock = NSLock()

    init(_ condition: @escaping () -> Bool) {
      self.condition = condition
    }

    func check() -> Bool {
      lock.lock(); defer { lock.unlock() }
      return condition()
    }
  }
}
