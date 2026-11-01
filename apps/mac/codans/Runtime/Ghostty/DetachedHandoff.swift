import CodansCore
import Foundation

/// Hands a detached pane's signals over from its watcher to a new surface,
/// so every signal reaches the app exactly once.
///
/// The switch point is a fence in the output stream. While the surface
/// attaches, the engine keeps sending fences through the daemon's `.Mark`
/// command over the watcher's own socket, so the daemon receives them in
/// the order they were registered here. A fence is an OSC 7501 `clear`
/// for a reserved id; the daemon broadcasts it to every client in order
/// with the PTY output, and only between escape sequences. The watcher
/// reads every fence; the surface reads only the fences sent after it
/// connected. The first fence the surface reports, `k`, splits the
/// stream: the watcher delivers what it read before fence `k`, the surface
/// what it read after it, and both drop the rest. Nothing is matched by
/// value, so equal signals on either side of the fence stay distinct.
///
/// Delivery follows stream order. Surface signals after fence `k` wait
/// until the watcher has read fence `k`, so a newer surface signal never
/// overtakes an older one the watcher has not read yet.
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
  /// Surface signals after the split, waiting for the watcher to reach it.
  private var surfaceHeld: [DetachedPaneSignal] = []

  init(watcherToken: UUID) {
    self.watcherToken = watcherToken
  }

  enum WatcherStep: Equatable, Sendable {
    case deliver
    case hold
    case drop
    /// The watcher read the split fence: stop it, drop the rest, then
    /// deliver the surface signals that waited for this point.
    case complete([DetachedPaneSignal])
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
      if let split = surfaceFence, index >= split { return .complete(takeSurfaceHeld()) }
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
    /// Deliver the signal now. False while it waits (see `surfaceHeld`) or
    /// when the watcher covers it.
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
      guard let split = surfaceFence else { return SurfaceStep(admit: false) }
      if watcherPassed > split { return SurfaceStep(admit: true) }
      surfaceHeld.append(signal)
      return SurfaceStep(admit: false)
    }
    guard surfaceFence == nil, let split = fences.firstIndex(of: id) else {
      return SurfaceStep(admit: false)
    }
    surfaceFence = split
    let release = held.filter { $0.segment <= split }.map(\.signal)
    held.removeAll()
    return SurfaceStep(admit: false, release: release, complete: watcherPassed > split)
  }

  struct Abandonment: Equatable, Sendable {
    /// Signals to deliver now, in stream order.
    var release: [DetachedPaneSignal]
    /// True: the surface becomes the source and the watcher stops. False:
    /// the watcher stays the pane's only source.
    var surfaceTakesOver: Bool
  }

  /// Give up after the timeout.
  /// - The surface never read a fence (a daemon without `.Mark`, or a
  ///   surface that never connected): the watcher has read everything, so
  ///   it stays the pane's only source. Nothing is lost.
  /// - The watcher never reached the split (it lost its connection, which
  ///   only an outside `DetachAll` causes): the surface takes over with
  ///   what it read after the split.
  mutating func abandon() -> Abandonment {
    defer {
      held.removeAll()
      surfaceHeld.removeAll()
    }
    guard surfaceFence != nil else {
      return Abandonment(release: held.map(\.signal), surfaceTakesOver: false)
    }
    return Abandonment(release: surfaceHeld, surfaceTakesOver: true)
  }

  private mutating func takeSurfaceHeld() -> [DetachedPaneSignal] {
    defer { surfaceHeld.removeAll() }
    return surfaceHeld
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
