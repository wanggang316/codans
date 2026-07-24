import Foundation
import os

/// Always-on launch-phase timing for `AppState.bringUp()`.
///
/// The synchronous bring-up path builds the whole app stack on the main
/// actor before the first real frame; when a launch feels slow we need to
/// know *which* stage cost the time without attaching Instruments. Each
/// `mark` emits an os_signpost event (Instruments → Points of Interest) and
/// a Console line carrying the phase's own duration plus the cumulative time
/// since bring-up began, filterable in Console.app by
/// `subsystem:com.gumpw.codans.runtime category:runtime.launch`.
///
/// Deliberately cheap: a handful of marks, each a couple of microseconds —
/// left in the shipping build so a regression is attributable from a user's
/// Console log rather than requiring a local repro.
@MainActor
final class LaunchProfiler {
  static let signposter = OSSignposter(
    subsystem: "com.gumpw.codans.runtime", category: "launch"
  )
  private static let logger = Logger(
    subsystem: "com.gumpw.codans.runtime", category: "runtime.launch"
  )

  private let clock = ContinuousClock()
  private let start: ContinuousClock.Instant
  private var last: ContinuousClock.Instant

  init() {
    let now = clock.now
    self.start = now
    self.last = now
  }

  /// Record the phase that just finished. Logs the delta since the previous
  /// mark and the running total since bring-up began; emits a signpost event
  /// tagged `name` for the Instruments timeline.
  func mark(_ name: StaticString) {
    let now = clock.now
    let phase = Self.milliseconds(last.duration(to: now))
    let total = Self.milliseconds(start.duration(to: now))
    last = now
    Self.signposter.emitEvent(name)
    Self.logger.info(
      "launch \(name, privacy: .public): +\(phase, privacy: .public) ms (total \(total, privacy: .public) ms)"
    )
  }

  /// Whole-integer milliseconds from a `Duration` (1 ms == 1e15 attoseconds).
  private static func milliseconds(_ duration: Duration) -> Int {
    let components = duration.components
    return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
  }
}
