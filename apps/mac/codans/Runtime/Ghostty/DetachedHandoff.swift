import CodansCore
import Foundation

/// Hands a detached pane's signals over from its watcher to a new surface,
/// so every signal reaches the app exactly once.
///
/// The switch point is a fence in the output stream. While the surface
/// attaches, the engine keeps sending fences through the daemon's `.Mark`
/// command: an OSC 7501 `clear` for a reserved id, which the daemon
/// broadcasts to every client in order with the PTY output. The watcher
/// reads every fence; the surface reads only the fences sent after it
/// connected. The first fence the surface reports, `k`, splits the
/// stream: the watcher delivers what it read before fence `k`, the surface
/// delivers what it read after it, and both drop the rest. Nothing is
/// matched by value, so equal signals on either side of the fence stay
/// distinct.
nonisolated struct DetachedHandoff: Sendable {
  /// The watcher that hands over.
  let watcherToken: UUID
  /// Fences sent so far, in order.
  private(set) var fences: [String] = []
  /// Fences the watcher has read. Its signals are in segment
  /// `watcherPassed`: after fence `watcherPassed - 1`, before the next.
  private(set) var watcherPassed = 0
  /// Index of the first fence the surface read, once known.
  private(set) var surfaceFence: Int?
  /// Watcher signals read after a fence while the split was unknown.
  private var held: [(segment: Int, signal: DetachedPaneSignal)] = []

  init(watcherToken: UUID) {
    self.watcherToken = watcherToken
  }

  enum WatcherStep: Equatable, Sendable {
    case deliver
    case hold
    case drop
    /// The watcher read the split fence: stop it, drop the rest.
    case complete
  }

  /// Register a new fence and return its payload id.
  mutating func nextFence() -> String {
    let id = Self.fencePrefix + String(UInt64.random(in: 0...UInt64.max), radix: 16)
    fences.append(id)
    return id
  }

  mutating func watcherRead(_ signal: DetachedPaneSignal) -> WatcherStep {
    if let id = Self.fenceID(of: signal) {
      guard let index = fences.firstIndex(of: id) else { return .drop }
      watcherPassed = max(watcherPassed, index + 1)
      if let split = surfaceFence, index >= split { return .complete }
      return .drop
    }
    if watcherPassed == 0 { return .deliver }
    guard let split = surfaceFence else {
      held.append((watcherPassed, signal))
      return .hold
    }
    return watcherPassed <= split ? .deliver : .drop
  }

  struct SurfaceStep: Equatable, Sendable {
    var admit: Bool
    /// Held watcher signals that turned out to precede the split.
    var release: [DetachedPaneSignal] = []
    /// The watcher already read the split fence: stop it now.
    var complete = false
  }

  mutating func surfaceRead(_ signal: DetachedPaneSignal) -> SurfaceStep {
    guard let id = Self.fenceID(of: signal) else {
      // Before its first fence, the surface reads output the watcher also
      // read before that fence and delivers.
      return SurfaceStep(admit: surfaceFence != nil)
    }
    guard surfaceFence == nil, let split = fences.firstIndex(of: id) else {
      return SurfaceStep(admit: false)
    }
    surfaceFence = split
    let release = held.filter { $0.segment <= split }.map(\.signal)
    held.removeAll()
    return SurfaceStep(admit: false, release: release, complete: watcherPassed > split)
  }

  /// Give up (the daemon ignores `.Mark`, or the surface never connected):
  /// returns the held signals, which only the watcher read so far.
  mutating func abandon() -> [DetachedPaneSignal] {
    defer { held.removeAll() }
    return held.map(\.signal)
  }

  // MARK: - Fence encoding

  /// Reserved OSC 7501 id prefix; a valid id (name segments joined by `/`).
  static let fencePrefix = "codans-handoff/"

  /// The bytes the daemon broadcasts for fence `id`.
  static func fenceBytes(_ id: String) -> Data {
    Data("\u{1B}]7501;state=clear:id=\(id)\u{1B}\\".utf8)
  }

  /// The fence id when `signal` is a handoff fence. Fences are never
  /// delivered as program status, with or without a handoff.
  static func fenceID(of signal: DetachedPaneSignal) -> String? {
    guard case .programStatus(let report) = signal, report.state == .clear,
      report.id.hasPrefix(fencePrefix)
    else { return nil }
    return report.id
  }
}
