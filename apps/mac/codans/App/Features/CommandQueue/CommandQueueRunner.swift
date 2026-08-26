import CodansCore
import Foundation
import OSLog

private let runnerLogger = Logger(
  subsystem: "com.gumpw.codans.commandqueue", category: "runner"
)

/// Drains every Pane's `commandQueue`: one poll pass decides which parked
/// command is due and writes it into that pane's terminal.
///
/// Polling rather than event-subscribing is deliberate. Two of the three
/// firing conditions are wall-clock (`scheduled`, and its repeat re-arm), so a
/// timer is required regardless; folding the readiness condition into the same
/// pass keeps a single code path with a single ordering guarantee instead of
/// racing a timer against an event stream. A pass costs one catalog walk over
/// panes that actually hold a queue.
///
/// State that must persist (the queue itself, a repeat's next occurrence)
/// lives on `Pane.commandQueue`; the only thing held here is the per-pane
/// settle log, which is meaningless across a relaunch.
@MainActor
final class CommandQueueRunner {
  /// Poll cadence. Fast enough that "after the current task" feels immediate
  /// and a scheduled minute lands on the right minute; slow enough that the
  /// catalog walk is invisible.
  static let tickInterval: Duration = .milliseconds(500)

  /// Minimum gap between two commands landing in the same pane.
  ///
  /// Readiness is derived from rendered terminal state, which lags the
  /// keystroke that starts the work — an agent handed a prompt still reads as
  /// idle for a beat. Without this window a three-entry queue would empty
  /// itself into one prompt on consecutive ticks.
  static let settleWindow: TimeInterval = 3

  private let queuedPanes: @MainActor () -> [(paneID: PaneID, queue: [QueuedCommand])]
  private let setQueue: @MainActor (PaneID, [QueuedCommand]) -> Void
  private let isPaneReady: @MainActor (PaneID) -> Bool
  private let hasLiveSurface: @MainActor (PaneID) -> Bool
  private let send: @MainActor (PaneID, String) -> Void
  private let now: () -> Date

  /// Last fire per pane, pruned to the settle window on every pass so the
  /// map can't grow with the session.
  private var lastFiredAt: [PaneID: Date] = [:]
  private var tickTask: Task<Void, Never>?

  init(
    queuedPanes: @escaping @MainActor () -> [(paneID: PaneID, queue: [QueuedCommand])],
    setQueue: @escaping @MainActor (PaneID, [QueuedCommand]) -> Void,
    isPaneReady: @escaping @MainActor (PaneID) -> Bool,
    hasLiveSurface: @escaping @MainActor (PaneID) -> Bool,
    send: @escaping @MainActor (PaneID, String) -> Void,
    now: @escaping () -> Date = Date.init
  ) {
    self.queuedPanes = queuedPanes
    self.setQueue = setQueue
    self.isPaneReady = isPaneReady
    self.hasLiveSurface = hasLiveSurface
    self.send = send
    self.now = now
  }

  // Explicit — a synthesized deinit on a MainActor-isolated class is itself
  // isolated, and hopping actors during dealloc is what trips libmalloc under
  // SwiftUI teardown. `Task.cancel()` is nonisolated and `Task?` is Sendable,
  // so this body is sound from the nonisolated tail an explicit deinit gets.
  deinit {
    tickTask?.cancel()
  }

  func start() {
    guard tickTask == nil else { return }
    tickTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.tickInterval)
        guard !Task.isCancelled, let self else { return }
        self.drain()
      }
    }
  }

  func stop() {
    tickTask?.cancel()
    tickTask = nil
  }

  /// One drain pass. Exposed (rather than buried in the tick loop) so tests
  /// drive it directly against an injected clock.
  ///
  /// Returns the panes that fired this pass — diagnostics and test assertions
  /// only; callers in the app ignore it.
  @discardableResult
  func drain() -> [PaneID] {
    let now = now()
    var fired: [PaneID] = []

    for (paneID, queue) in queuedPanes() {
      // No surface means `send` would write into nothing and the entry would
      // be consumed for real. Hold the whole pane until it materialises —
      // a scheduled command that came due while its tab was never opened
      // this session fires once, on the tick after the surface exists.
      guard hasLiveSurface(paneID) else { continue }
      if let last = lastFiredAt[paneID], now.timeIntervalSince(last) < Self.settleWindow {
        continue
      }
      guard let command = queue.nextToFire(now: now, isReady: isPaneReady(paneID)) else {
        continue
      }
      runnerLogger.info(
        "fire pane=\(paneID.raw.uuidString, privacy: .public) repeating=\(command.timing.isRepeating, privacy: .public)"
      )
      send(paneID, command.text + "\n")
      lastFiredAt[paneID] = now
      setQueue(paneID, queue.advancing(command, firedAt: now))
      fired.append(paneID)
    }

    lastFiredAt = lastFiredAt.filter { now.timeIntervalSince($0.value) < Self.settleWindow }
    return fired
  }
}

extension CommandQueueRunner {
  /// Readiness predicate shared by the runner and anything else that needs
  /// "is this pane between tasks".
  ///
  /// Agent panes are judged by the agent state machine, never by the raw
  /// terminal-busy sets: coding agents emit progress sequences throughout a
  /// task, so the busy union never goes quiet while one is working. `blocked`
  /// is deliberately not ready — the agent is waiting on an answer to a
  /// specific question, and a queued prompt typed there would be consumed as
  /// that answer.
  ///
  /// Panes with no bound agent fall back to "no foreground command running".
  static func isReady(
    agentState: AgentStateStore.AgentRuntimeState?,
    terminalBusy: Bool
  ) -> Bool {
    if let agentState {
      return agentState == .idle || agentState == .finished
    }
    return !terminalBusy
  }
}
