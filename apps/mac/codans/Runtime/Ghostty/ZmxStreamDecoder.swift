import Foundation

/// Pure state machine that turns an observer connection's zmx frames into
/// a gap-free terminal stream.
///
/// The daemon broadcasts PTY output to every client, so live `.output`
/// frames start flowing the moment the observer connects — before any
/// snapshot. The decoder drops them while `syncing`: the daemon queues its
/// snapshot reply behind every output it had already written to this
/// client, so everything dropped is inside the snapshot and everything
/// after the reply is new. The result has no gap and no duplicate.
///
/// A daemon older than the observer protocol ignores `.observe`. If no
/// `.observeState` arrives in time the owner calls
/// `fallbackDeadlinePassed()`, and the decoder switches to a `.history`
/// (`vt`) snapshot, which has the same ordering guarantee but no size and
/// an unreliable cursor, so it is reported as approximate.
nonisolated struct ZmxStreamDecoder: Equatable, Sendable {
  enum Mode: Equatable, Sendable {
    /// `.observe` / `.observeState`: exact snapshots, pushed resizes.
    case observe
    /// `.history` fallback for daemons without the observer protocol.
    case history
  }

  enum Phase: Equatable, Sendable {
    case idle
    /// A snapshot was requested; output is dropped until it arrives.
    case syncing(Mode)
    case live(Mode)
  }

  /// What the owner must send on the connection.
  enum Command: Equatable, Sendable {
    case sendObserve
    case sendHistory
  }

  /// What the connection produced, in stream order.
  enum Event: Equatable, Sendable {
    /// Exact snapshot from `.observeState`.
    case snapshot(cols: UInt16, rows: UInt16, state: Data)
    /// `.history` snapshot: no size (the owner supplies one) and an
    /// approximate cursor.
    case historySnapshot(Data)
    case output(Data)
    case resized(cols: UInt16, rows: UInt16)
  }

  private(set) var phase: Phase = .idle

  /// The mode new snapshots use.
  var mode: Mode {
    switch phase {
    case .idle: return .observe
    case .syncing(let mode), .live(let mode): return mode
    }
  }

  var isLive: Bool {
    if case .live = phase { return true }
    return false
  }

  /// Opens the stream by asking for an observer snapshot.
  mutating func start() -> Command {
    phase = .syncing(.observe)
    return .sendObserve
  }

  /// No `.observeState` arrived in time: fall back to `.history`. Nil when
  /// the observer snapshot already landed (or the stream never started).
  mutating func fallbackDeadlinePassed() -> Command? {
    guard phase == .syncing(.observe) else { return nil }
    phase = .syncing(.history)
    return .sendHistory
  }

  /// Asks for a fresh snapshot in the current mode — after the owner
  /// dropped output it could not deliver, or after a resize the daemon
  /// cannot report (history mode).
  mutating func resync() -> Command {
    let mode = mode
    phase = .syncing(mode)
    return mode == .observe ? .sendObserve : .sendHistory
  }

  /// Feeds one frame; nil when the frame is dropped.
  mutating func receive(_ frame: ZmxFrame) throws -> Event? {
    switch frame.tag {
    case .output:
      guard isLive else { return nil }
      return .output(frame.payload)
    case .observeState:
      guard phase != .idle else { return nil }
      // Also accepted in history mode: a slow observer-capable daemon
      // answered after the fallback fired. Its snapshot is exact, so
      // switch back; the history reply still in flight is then ignored.
      let state = try ZmxObserveStatePayload.decode(frame.payload)
      phase = .live(.observe)
      return .snapshot(cols: state.cols, rows: state.rows, state: state.state)
    case .history:
      guard mode == .history, phase != .idle else { return nil }
      phase = .live(.history)
      return .historySnapshot(frame.payload)
    case .observeResize:
      // While syncing, the pending snapshot carries the new size.
      guard isLive else { return nil }
      let size = try ZmxResizePayload.decode(frame.payload)
      return .resized(cols: size.cols, rows: size.rows)
    default:
      return nil
    }
  }
}
