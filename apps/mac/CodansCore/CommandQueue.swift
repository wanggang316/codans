import Foundation

/// One entry in a Pane's command queue: the literal text to type into that
/// pane's terminal, plus the rule deciding *when* it is typed.
///
/// Persisted on `Pane.commandQueue`. The Pane row — not its pty child — is
/// the identity a deferred command is attached to, the same reasoning that
/// puts `Pane.runScriptID` in the catalog: a relaunch restores the pane, so
/// it must also restore what that pane still owes the user.
///
/// "Send now" is deliberately *not* a case here. A command the user asked to
/// deliver immediately is written straight to the surface and never becomes a
/// queue entry, so nothing that reaches this type is already-delivered work.
public nonisolated struct QueuedCommand: Identifiable, Equatable, Sendable, Codable {
  public var id: UUID
  /// Text delivered to the pane verbatim. The trailing newline that submits
  /// it is added by the sender, so this stores exactly what the user typed.
  public var text: String
  public var timing: QueuedCommandTiming
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    text: String,
    timing: QueuedCommandTiming,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.text = text
    self.timing = timing
    self.createdAt = createdAt
  }
}

/// When a `QueuedCommand` is allowed to fire.
///
/// Encoded as a `kind`-tagged object rather than Swift's synthesized
/// single-key enum form so the JSON stays legible in `catalog.json` and so a
/// future case is a decode error on exactly one entry — `Pane` decodes the
/// queue leniently, dropping an undecodable queue instead of failing the
/// whole catalog.
public nonisolated enum QueuedCommandTiming: Equatable, Sendable {
  /// Wait until the pane goes quiet, then fire. "Quiet" is the app's
  /// readiness predicate, not a raw byte-level idle: for a pane running a
  /// coding agent it is the agent's own `idle` / `finished` state, because
  /// agents emit terminal progress sequences throughout a task and their
  /// `blocked` state means they are waiting on a specific answer that a
  /// queued prompt must not hijack.
  case afterCurrentTask
  /// Fire at `date`. When `repeatEvery` is non-nil the entry re-arms to the
  /// next occurrence after each fire instead of leaving the queue.
  case scheduled(at: Date, repeatEvery: TimeInterval?)
}

extension QueuedCommandTiming {
  /// The moment this timing wants to fire, or `nil` for the event-driven
  /// case. Reading it is how the runner decides whether a tick is due.
  public var fireDate: Date? {
    switch self {
    case .afterCurrentTask: return nil
    case .scheduled(let date, _): return date
    }
  }

  /// Repeat interval, or `nil` for a one-shot entry.
  public var repeatEvery: TimeInterval? {
    switch self {
    case .afterCurrentTask: return nil
    case .scheduled(_, let interval): return interval
    }
  }

  public var isRepeating: Bool { (repeatEvery ?? 0) > 0 }

  /// The timing this entry carries after firing at `now`, or `nil` when the
  /// entry is spent and should leave the queue.
  ///
  /// A repeating schedule advances to its next occurrence strictly after
  /// `now`, skipping every occurrence that elapsed while the app was closed.
  /// That is what makes a relaunch fire a past-due repeat exactly once (the
  /// due tick) rather than replaying every missed period.
  public func advanced(firedAt now: Date) -> QueuedCommandTiming? {
    switch self {
    case .afterCurrentTask:
      return nil
    case .scheduled(let date, let interval):
      guard let interval, interval > 0 else { return nil }
      return .scheduled(at: Self.nextOccurrence(from: date, every: interval, after: now), repeatEvery: interval)
    }
  }

  /// First `start + k * interval` strictly greater than `after`. Computed
  /// arithmetically rather than by looping so a schedule left behind by a
  /// week-long shutdown costs one division, not 20 000 iterations.
  static func nextOccurrence(from start: Date, every interval: TimeInterval, after: Date) -> Date {
    let elapsed = after.timeIntervalSince(start)
    guard elapsed >= 0 else { return start }
    let periods = (elapsed / interval).rounded(.down) + 1
    return start.addingTimeInterval(periods * interval)
  }
}

// MARK: - Codable

extension QueuedCommandTiming: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, at, repeatEvery
  }

  private enum Kind: String, Codable {
    case afterCurrentTask
    case scheduled
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    switch kind {
    case .afterCurrentTask:
      self = .afterCurrentTask
    case .scheduled:
      self = .scheduled(
        at: try container.decode(Date.self, forKey: .at),
        repeatEvery: try container.decodeIfPresent(TimeInterval.self, forKey: .repeatEvery)
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .afterCurrentTask:
      try container.encode(Kind.afterCurrentTask, forKey: .kind)
    case .scheduled(let date, let interval):
      try container.encode(Kind.scheduled, forKey: .kind)
      try container.encode(date, forKey: .at)
      try container.encodeIfPresent(interval, forKey: .repeatEvery)
    }
  }
}

// MARK: - Queue policy

extension Array where Element == QueuedCommand {
  /// The entry a drain pass should fire, given the pane's readiness and the
  /// current time — or `nil` when nothing is due.
  ///
  /// Scheduled entries win over queued ones and are honoured regardless of
  /// readiness: the user asked for a wall-clock time, so a busy pane must not
  /// silently postpone it. Among queued entries only the head fires, and only
  /// when the pane is ready — draining more than one per pass would dump the
  /// whole queue into a single prompt.
  public func nextToFire(now: Date, isReady: Bool) -> QueuedCommand? {
    let due = filter { ($0.timing.fireDate ?? .distantFuture) <= now }
    if let earliest = due.min(by: { ($0.timing.fireDate ?? .distantFuture) < ($1.timing.fireDate ?? .distantFuture) }) {
      return earliest
    }
    guard isReady else { return nil }
    return first { $0.timing.fireDate == nil }
  }

  /// The queue after `command` has fired: repeating schedules re-armed in
  /// place (preserving position), everything else removed.
  public func advancing(_ command: QueuedCommand, firedAt now: Date) -> [QueuedCommand] {
    compactMap { entry in
      guard entry.id == command.id else { return entry }
      guard let next = entry.timing.advanced(firedAt: now) else { return nil }
      var rearmed = entry
      rearmed.timing = next
      return rearmed
    }
  }
}

// MARK: - What a close would discard

extension Tab {
  /// Queued commands parked on this tab's panes — what closing it discards.
  public var queuedCommandCount: Int {
    panes.reduce(0) { $0 + $1.commandQueue.count }
  }
}

extension Worktree {
  public var queuedCommandCount: Int {
    tabs.reduce(0) { $0 + $1.queuedCommandCount }
  }
}

extension Project {
  /// Counts archived worktrees too: their queues are dormant, but removing
  /// the project takes them along.
  public var queuedCommandCount: Int {
    worktrees.reduce(0) { $0 + $1.queuedCommandCount }
  }
}
