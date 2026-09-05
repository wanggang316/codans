import CodansCore
import Foundation
import Testing

@testable import Codans

/// A single modified file — enough to make `WorkingTreeStatus.isClean` false.
/// Top-level so the `@Sendable` fetch stubs below can read it.
private let dirtyEntry = WorkingTreeStatus.Entry(
  indexStatus: " ", worktreeStatus: "M", path: "a.txt", renamedFrom: nil
)

/// Coverage for `retain(liveWorktreeIDs:)` on the two sidebar git monitors.
///
/// Eviction alone is not enough: `refresh` awaits its fetch and then writes
/// the result unconditionally, so a request already in flight when the
/// Worktree is removed or archived would put the entry straight back — and
/// stamp a fresh `lastFetchedAt` that blocks a real refresh for the whole
/// freshness window if the Worktree returns.
@MainActor
struct WorktreeMonitorRetainTests {
  // MARK: - WorktreeStatusMonitor

  @Test
  func statusRetainDropsEntriesForVanishedWorktrees() async {
    let gate = Gate()
    let monitor = WorktreeStatusMonitor(fetch: { _ in
      gate.markEntered()
      await gate.wait()
      return WorkingTreeStatus(entries: [dirtyEntry])
    })
    let live = WorktreeID()
    let gone = WorktreeID()

    async let liveRun: Void = monitor.refresh(worktreeID: live, path: URL(fileURLWithPath: "/repo"))
    async let goneRun: Void = monitor.refresh(worktreeID: gone, path: URL(fileURLWithPath: "/gone"))
    await gate.waitUntilEntered(2)
    gate.open()
    _ = await (liveRun, goneRun)

    #expect(monitor.isDirty[live] == true)
    #expect(monitor.isDirty[gone] == true)

    monitor.retain(liveWorktreeIDs: [live])

    #expect(monitor.isDirty[live] == true)
    #expect(monitor.isDirty[gone] == nil)
  }

  @Test
  func statusRetainDiscardsAResultThatWasAlreadyInFlight() async {
    let gate = Gate()
    let monitor = WorktreeStatusMonitor(fetch: { _ in
      gate.markEntered()
      await gate.wait()
      return WorkingTreeStatus(entries: [dirtyEntry])
    })
    let gone = WorktreeID()

    async let run: Void = monitor.refresh(worktreeID: gone, path: URL(fileURLWithPath: "/gone"))
    await gate.waitUntilEntered()

    // Archive lands while `git status` is still running.
    monitor.retain(liveWorktreeIDs: [])
    gate.open()
    await run

    #expect(monitor.isDirty[gone] == nil)
    // No freshness stamp either, so an unarchive can fetch again immediately
    // instead of reusing the discarded result's timestamp.
    await monitor.refresh(worktreeID: gone, path: URL(fileURLWithPath: "/gone"))
    #expect(monitor.isDirty[gone] == true)
  }

  @Test
  func statusRefreshRequestedDuringADiscardedRunIsServedAfterwards() async {
    let gate = Gate()
    let monitor = WorktreeStatusMonitor(fetch: { _ in
      gate.markEntered()
      await gate.wait()
      return WorkingTreeStatus(entries: [dirtyEntry])
    })
    let wid = WorktreeID()
    let path = URL(fileURLWithPath: "/repo")

    async let first: Void = monitor.refresh(worktreeID: wid, path: path)
    await gate.waitUntilEntered()

    // Archive, then unarchive before the first `git status` returns. The
    // sidebar row remounts and asks again, but the first request still holds
    // the in-flight slot, so this call cannot start its own fetch.
    monitor.retain(liveWorktreeIDs: [])
    monitor.retain(liveWorktreeIDs: [wid])
    await monitor.refresh(worktreeID: wid, path: path)
    #expect(monitor.isDirty[wid] == nil)

    gate.open()
    await first

    // The discarded run must hand off to the request it displaced —
    // `.task(id:)` has already fired and will not retry on its own.
    #expect(monitor.isDirty[wid] == true)
  }

  // MARK: - WorktreeLocalDiffMonitor

  @Test
  func localDiffRetainDiscardsAResultThatWasAlreadyInFlight() async {
    let gate = Gate()
    let stats = LocalDiffStats(additions: 2, deletions: 3)
    let monitor = WorktreeLocalDiffMonitor(fetch: { _ in
      gate.markEntered()
      await gate.wait()
      return stats
    })
    let gone = WorktreeID()

    async let run: Void = monitor.refresh(worktreeID: gone, path: URL(fileURLWithPath: "/gone"))
    await gate.waitUntilEntered()

    monitor.retain(liveWorktreeIDs: [])
    gate.open()
    await run

    #expect(monitor.stats[gone] == nil)
    await monitor.refresh(worktreeID: gone, path: URL(fileURLWithPath: "/gone"))
    #expect(monitor.stats[gone] == stats)
  }

  @Test
  func localDiffRefreshRequestedDuringADiscardedRunIsServedAfterwards() async {
    let gate = Gate()
    let stats = LocalDiffStats(additions: 2, deletions: 3)
    let monitor = WorktreeLocalDiffMonitor(fetch: { _ in
      gate.markEntered()
      await gate.wait()
      return stats
    })
    let wid = WorktreeID()
    let path = URL(fileURLWithPath: "/repo")

    async let first: Void = monitor.refresh(worktreeID: wid, path: path)
    await gate.waitUntilEntered()

    monitor.retain(liveWorktreeIDs: [])
    monitor.retain(liveWorktreeIDs: [wid])
    await monitor.refresh(worktreeID: wid, path: path)
    #expect(monitor.stats[wid] == nil)

    gate.open()
    await first

    #expect(monitor.stats[wid] == stats)
  }

  /// One-shot gate so a test can hold a stubbed fetch open across a `retain`,
  /// then release it. Models `git status` still running when the catalog
  /// mutates underneath it.
  private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var enteredCount = 0
    private var awaitedEntries = 0

    /// Called by the stub the moment it starts, before it blocks. Lets the
    /// test know the fetch is genuinely in flight — `Task.yield()` alone does
    /// not guarantee the child task has reached the monitor's actor.
    func markEntered() {
      lock.lock()
      enteredCount += 1
      let waiters = enteredCount >= awaitedEntries ? enteredWaiters : []
      if !waiters.isEmpty { enteredWaiters = [] }
      lock.unlock()
      for c in waiters { c.resume() }
    }

    func waitUntilEntered(_ count: Int = 1) async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        lock.lock()
        awaitedEntries = count
        if enteredCount >= count {
          lock.unlock()
          c.resume()
          return
        }
        enteredWaiters.append(c)
        lock.unlock()
      }
    }

    func wait() async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        lock.lock()
        if opened {
          lock.unlock()
          c.resume()
          return
        }
        continuations.append(c)
        lock.unlock()
      }
    }

    func open() {
      lock.lock()
      opened = true
      let pending = continuations
      continuations = []
      lock.unlock()
      for c in pending { c.resume() }
    }
  }
}
