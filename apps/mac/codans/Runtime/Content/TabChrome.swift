import Foundation
import Observation

/// What a live Content reports about itself for the strip: title,
/// progress, and read-only state. A terminal Content points this at its
/// surface's info object so the chip follows libghostty's reports without
/// a copy step; a test Content supplies a fixed one.
@MainActor
protocol TabChromeSource: AnyObject {
  var chromeTitle: String? { get }
  /// 0...1, or `nil` when no determinate progress is reported.
  var chromeProgress: Double? { get }
  var chromeIsReadOnly: Bool { get }
}

/// The strip-facing state of one Content. One instance per registered
/// Content, owned by its `TabContent`; the chip reads it through
/// `ContentRuntime.chrome(for:)`.
///
/// `isBusy` and `isCommandBusy` are the two "terminal busy" sources the
/// strip ORs together: OSC 9;4 progress reports and a running foreground
/// command. They are written by separate producers, so they are separate
/// flags — one writer must never clobber the other's state.
@MainActor
@Observable
final class TabChrome {
  /// A tracked operation is in flight according to OSC 9;4.
  var isBusy = false
  /// The foreground process group is a real running command (see
  /// `ForegroundJobClassifier`).
  var isCommandBusy = false
  /// Count shown on the chip, `nil` for none.
  var badge: Int?
  /// Live source for title / progress / read-only, when the Content has
  /// one. Reads go through it so observation follows the source's own
  /// property changes.
  var source: (any TabChromeSource)?

  var isTerminalBusy: Bool { isBusy || isCommandBusy }
  var progress: Double? { source?.chromeProgress }
  var isReadOnly: Bool { source?.chromeIsReadOnly ?? false }
  var liveTitle: String? { source?.chromeTitle }

  init() {}

  // Explicit nonisolated deinit: the synthesized isolated deinit of a
  // `@MainActor @Observable` class double-frees inside a cascading
  // teardown (see `TerminalEngine.deinit`).
  deinit {}
}
