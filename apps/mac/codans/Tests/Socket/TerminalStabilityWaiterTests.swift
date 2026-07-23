import Foundation
import Testing

@testable import Codans

/// Direct tests for the wait-stable poll loop. An auto-advancing virtual
/// clock drives the whole loop with zero real delay, so timing assertions
/// are deterministic — that injectable clock is the whole point of the type.
@MainActor
struct TerminalStabilityWaiterTests {
  /// `sleep` advances virtual time instantly and returns; `nowMillis`
  /// reports the accumulated total. Single-threaded (main actor) use, so
  /// no locking is needed.
  final class VirtualClock: StabilityClock, @unchecked Sendable {
    private(set) var current = 0
    func nowMillis() -> Int { current }
    func sleep(millis: Int) async throws {
      // A real suspension point (models a real sleep) while advancing only
      // virtual time, so the poll loop stays deterministic with no delay.
      await Task.yield()
      current += max(0, millis)
    }
  }

  /// Returns each element of `script` in turn, clamping to the last once
  /// exhausted — models output that changes then holds steady.
  private func scriptedReader(_ script: [String?]) -> @MainActor () -> String? {
    var index = 0
    return {
      defer { index += 1 }
      return index < script.count ? script[index] : script.last ?? nil
    }
  }

  @Test
  func stabilizesAfterOutputSettles() async {
    let clock = VirtualClock()
    let waiter = TerminalStabilityWaiter(
      clock: clock, stableMillis: 30, intervalMillis: 10, timeoutMillis: 1000,
      read: scriptedReader(["a", "ab", "abc"]))  // grows, then holds on "abc"
    let outcome = await waiter.run()
    #expect(outcome?.text == "abc")
    #expect(outcome?.stabilized == true)
    #expect((outcome?.samples ?? 0) >= 2)
    #expect((outcome?.waitedMillis ?? 0) >= 30)
  }

  @Test
  func alreadyStaticOutputStabilizesAfterWindow() async {
    let clock = VirtualClock()
    let waiter = TerminalStabilityWaiter(
      clock: clock, stableMillis: 30, intervalMillis: 10, timeoutMillis: 1000,
      read: { "steady" })
    let outcome = await waiter.run()
    #expect(outcome?.text == "steady")
    #expect(outcome?.stabilized == true)
    // Static from the first read: window elapses without a reset.
    #expect(outcome?.waitedMillis == 30)
  }

  @Test
  func timesOutWhenOutputNeverSettles() async {
    let clock = VirtualClock()
    var counter = 0
    let waiter = TerminalStabilityWaiter(
      clock: clock, stableMillis: 50, intervalMillis: 10, timeoutMillis: 45,
      read: {
        defer { counter += 1 }
        return "line-\(counter)"  // always different
      })
    let outcome = await waiter.run()
    #expect(outcome?.stabilized == false)
    #expect((outcome?.waitedMillis ?? 0) >= 45)
    #expect(outcome?.text == "line-\(counter - 1)")  // the last sample taken
  }

  @Test
  func returnsNilWhenPaneNotFoundOnFirstRead() async {
    let clock = VirtualClock()
    let waiter = TerminalStabilityWaiter(
      clock: clock, stableMillis: 30, intervalMillis: 10, timeoutMillis: 1000,
      read: { nil })
    let outcome = await waiter.run()
    #expect(outcome == nil)
  }

  @Test
  func stopsWhenPaneVanishesMidWait() async {
    let clock = VirtualClock()
    let waiter = TerminalStabilityWaiter(
      clock: clock, stableMillis: 100, intervalMillis: 10, timeoutMillis: 1000,
      read: scriptedReader(["running", nil]))  // one read, then the pane is gone
    let outcome = await waiter.run()
    #expect(outcome?.text == "running")
    #expect(outcome?.stabilized == false)
    #expect(outcome?.samples == 1)
  }
}
