import Foundation

/// Monotonic time + sleep, abstracted so `TerminalStabilityWaiter` can be
/// unit-tested with a virtual clock (no real waiting). Production uses
/// `SystemStabilityClock`; tests inject an auto-advancing fake.
public protocol StabilityClock: Sendable {
  /// Monotonic milliseconds. Only deltas are meaningful; the origin is
  /// unspecified.
  func nowMillis() -> Int
  /// Suspend for `millis`. May resume early on cancellation (throws).
  func sleep(millis: Int) async throws
}

/// Real clock: `DispatchTime` for the monotonic read, `Task.sleep` for the
/// wait. Stateless, so it is trivially `Sendable`.
public struct SystemStabilityClock: StabilityClock {
  public init() {}

  public func nowMillis() -> Int {
    Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
  }

  public func sleep(millis: Int) async throws {
    guard millis > 0 else { return }
    try await Task.sleep(nanoseconds: UInt64(millis) * 1_000_000)
  }
}

/// Polls a pane's rendered text until it stops changing for a quiet window,
/// or a timeout elapses — the "wait until the command/agent actually
/// settled" primitive for scripted `terminal.readText` reads.
///
/// The loop samples `read()` every `intervalMillis`; each unchanged sample
/// extends a stability window, each changed sample resets it. Once the
/// output has held steady for `stableMillis` the read is `stabilized`;
/// hitting `timeoutMillis` first returns the latest text unstabilized.
/// Time and sleeping both route through an injected `StabilityClock`, so
/// tests drive the whole loop deterministically with zero real delay.
@MainActor
struct TerminalStabilityWaiter {
  struct Outcome: Equatable {
    let text: String
    let stabilized: Bool
    let waitedMillis: Int
    let samples: Int
  }

  let clock: StabilityClock
  /// Quiet window the output must stay unchanged to count as stabilized.
  let stableMillis: Int
  /// Delay between successive samples.
  let intervalMillis: Int
  /// Overall cap before giving up and returning the latest text.
  let timeoutMillis: Int
  /// Reads the current rendered text. `nil` means the pane is gone; the
  /// first `nil` aborts the whole wait (caller maps it to `notFound`).
  let read: @MainActor () -> String?

  /// Runs the poll loop. Returns `nil` only when the very first read fails
  /// (pane not found); a pane that vanishes mid-wait yields the last text
  /// observed, unstabilized.
  func run() async -> Outcome? {
    let start = clock.nowMillis()
    guard var lastText = read() else { return nil }
    var samples = 1
    var lastChangeAt = start

    while true {
      let now = clock.nowMillis()
      let sinceChange = now - lastChangeAt
      let elapsed = now - start

      if sinceChange >= stableMillis {
        return Outcome(text: lastText, stabilized: true, waitedMillis: elapsed, samples: samples)
      }
      if elapsed >= timeoutMillis {
        return Outcome(text: lastText, stabilized: false, waitedMillis: elapsed, samples: samples)
      }

      // Sleep only as far as the next boundary (stable window or timeout),
      // capped by the poll interval, so a coarse interval never overshoots.
      let sleepMillis = max(1, min(intervalMillis, min(stableMillis - sinceChange, timeoutMillis - elapsed)))
      do {
        try await clock.sleep(millis: sleepMillis)
      } catch {
        return Outcome(
          text: lastText, stabilized: false, waitedMillis: clock.nowMillis() - start, samples: samples)
      }

      guard let next = read() else {
        return Outcome(
          text: lastText, stabilized: false, waitedMillis: clock.nowMillis() - start, samples: samples)
      }
      samples += 1
      if next != lastText {
        lastText = next
        lastChangeAt = clock.nowMillis()
      }
    }
  }
}
