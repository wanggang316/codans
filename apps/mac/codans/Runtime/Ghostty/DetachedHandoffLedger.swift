import Foundation

/// Exactly-once delivery while a detached pane's watcher hands over to a new
/// surface. The watcher keeps reading until the surface is attached to the
/// daemon, so no output falls between the two. In that overlap both clients
/// receive the same chunks, in the same order, and each one reports the
/// signals it finds; the ledger lets the first copy of a signal through and
/// drops the second.
///
/// The watcher's stream covers the surface's from both ends: it starts
/// earlier and ends later. When one source reports a signal the
/// other already delivered, every earlier unmatched entry of the other
/// source lies outside the overlap and can never match, so it is dropped.
nonisolated struct DetachedHandoffLedger: Sendable {
  enum Source: Sendable {
    case watcher
    case surface
  }

  /// Unmatched signals kept per source. The overlap lasts until the surface
  /// is attached (a few hundred milliseconds), so a small bound is enough.
  static let capacity = 64

  private var fromWatcher: [DetachedPaneSignal] = []
  private var fromSurface: [DetachedPaneSignal] = []

  init() {}

  /// Whether `signal` from `source` should be delivered.
  mutating func admit(_ signal: DetachedPaneSignal, from source: Source) -> Bool {
    switch source {
    case .watcher: return Self.admit(signal, into: &fromWatcher, matching: &fromSurface)
    case .surface: return Self.admit(signal, into: &fromSurface, matching: &fromWatcher)
    }
  }

  private static func admit(
    _ signal: DetachedPaneSignal,
    into own: inout [DetachedPaneSignal],
    matching other: inout [DetachedPaneSignal]
  ) -> Bool {
    if let index = other.firstIndex(of: signal) {
      other.removeSubrange(...index)
      return false
    }
    own.append(signal)
    if own.count > capacity { own.removeFirst(own.count - capacity) }
    return true
  }
}
