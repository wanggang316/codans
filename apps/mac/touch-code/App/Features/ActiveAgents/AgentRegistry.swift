import Foundation
import OSLog
import Observation
import TouchCodeCore

private let registryLogger = Logger(
  subsystem: "com.touch-code.activeagents", category: "registry"
)

/// Runtime-only state machine that derives each bound agent pane's
/// runtime state (`waitingForInput` / `loading` / `finished` / `idle`)
/// from a raw working/blocked/idle model plus an observed/unobserved
/// attention bit. Raw state comes from the OSC 9;4 progress stream, a
/// title-rate heuristic for TUI agents that don't emit OSC 9;4 around
/// model work, plus bell / notification side channels. Designed to be the
/// single source of truth for the ActiveAgents badge + popover
/// (T5–T7). Nothing is persisted: every entry is reconstructed from
/// the live event flow at process start.
///
/// `entries` is keyed by `PaneID` and exposes one `AgentEntry` per
/// pane that has been bound via `onAgentBound(_:kind:sessionID:)`. The
/// dictionary is `@Observable`-tracked so SwiftUI consumers re-render
/// on every transition; every mutation writes the full entry struct
/// back to the subscript so change tracking fires reliably.
///
/// Display priority is `waitingForInput > loading > finished > idle`.
/// The raw blocked flag is sticky until the user observably interacts
/// (keystroke / focus). Raw working fires only after the bound agent has
/// observed user input, from two sources: (1) OSC 9;4 progress — the live
/// `runningPanes` set; and (2) a *title-rate* signal — the bound pane's
/// `title` / `tabTitle` deltas exceed
/// `titleActivityThreshold` events inside the rolling
/// `titleActivityWindow`. Finished is not a raw state: it is the display
/// form of a pane that moved from active raw state back to idle while the
/// user was not looking at it.
///
/// Lifecycle teardown (`paneExited` / `paneCrashed` / `paneClosedByTab`)
/// drops both the entry and its scratch — the popover row disappears
/// when the user closes the pane. `onAgentUnbound` does the same
/// explicitly for the user-driven unbind path. The registry is
/// silently inert for unbound panes: events arrive, scratch stays
/// uninitialized, and `entries` never grows.
@MainActor
@Observable
final class AgentRegistry {
  /// One row in the registry. Pane-keyed via `entries`. `state` and
  /// `lastTransitionAt` are mutated in place; `kind` and `sessionID`
  /// are immutable for the entry's lifetime (rebind requires
  /// `onAgentUnbound` followed by `onAgentBound`).
  struct AgentEntry: Equatable {
    let kind: AgentKind
    let sessionID: String?
    var state: AgentRuntimeState
    var lastTransitionAt: Date
  }

  /// Derived runtime state surfaced to UI. Distinct from the
  /// inbox-side `InboxEntry.Kind` because `loading` and `idle` are
  /// purely in-process signals (the inbox never represents them);
  /// only `waitingForInput` overlaps in spirit.
  enum AgentRuntimeState: String, CaseIterable, Equatable, Sendable {
    case waitingForInput
    case loading
    case finished
    case idle
  }

  /// Public, read-only view of bound agents. `@Observable` tracks
  /// dictionary subscript writes so SwiftUI consumers re-render on
  /// every state transition.
  private(set) var entries: [PaneID: AgentEntry] = [:]

  /// Per-pane derivation scratch. Kept around for all panes the
  /// registry has heard about (bound or not) so signals that arrive
  /// before an agent is identified still leave the correct raw state
  /// and observation state when `onAgentBound` lands. Dropped on
  /// teardown / unbind.
  private struct Scratch {
    var rawState: AgentRawState
    var seen: Bool
    var userInputSeen: Bool
    var waitingForInput: Bool
    /// Sliding window of recent `title` / `tabTitle` event times.
    /// Append on each delta, trim to `titleActivityWindow`, then ask
    /// "is the rate above `titleActivityThreshold`?" before claiming
    /// the pane is doing work. A single sporadic title change at the
    /// input prompt (cursor moves, single redraw, focus restore) is
    /// not enough — a working TUI agent emits several updates per
    /// second (status spinner, token counter, etc.) and easily clears
    /// the bar.
    var titleEventTimes: [Date]
  }

  private enum AgentRawState: Equatable {
    case working
    case blocked
    case idle

    var isActive: Bool {
      self == .working || self == .blocked
    }
  }

  private var scratch: [PaneID: Scratch] = [:]

  /// Rolling window for title-rate detection.
  private static let titleActivityWindow: TimeInterval = 2.0

  /// Minimum number of title / tabTitle deltas inside
  /// `titleActivityWindow` for the pane to read as actively working.
  /// Picked low enough that a normal TUI status update (typically
  /// 2–5 Hz) clears the bar quickly, but high enough that a single
  /// stray redraw at the input prompt does not flip the row to
  /// `.loading`.
  private static let titleActivityThreshold: Int = 3

  /// Per-pane decay Task — fires `decayTitleActivity` once
  /// `titleActivityWindow` has elapsed without a fresh delta, so the
  /// registry leaves `.loading` even when the agent stops updating
  /// without firing any other event. Cancelled / replaced on every
  /// fresh title delta.
  private var titleDecayTasks: [PaneID: Task<Void, Never>] = [:]

  /// Snapshot of currently-running pane IDs (process attached + child
  /// alive). The registry samples this on every input.
  private let runningPanes: @MainActor () -> Set<PaneID>
  /// Globally focused pane, if any. Used to avoid surfacing
  /// `.finished` for work the user is already looking at; focus
  /// change events still clear a previously surfaced finished state.
  private let focusedPane: @MainActor () -> PaneID?
  /// Time source. Injected so tests can assert on `lastTransitionAt`
  /// without racing real `Date()`.
  private let now: () -> Date

  /// Last running-panes snapshot. Diffed against the next call to
  /// `onRunningPanesChanged(_:)` so we can distinguish "just entered"
  /// from "just left" without forcing callers to compute the delta.
  private var lastRunning: Set<PaneID> = []

  init(
    runningPanes: @escaping @MainActor () -> Set<PaneID>,
    focusedPane: @escaping @MainActor () -> PaneID?,
    now: @escaping () -> Date = Date.init
  ) {
    self.runningPanes = runningPanes
    self.focusedPane = focusedPane
    self.now = now
  }

  // MARK: - Inputs
  //
  // Reaction table (see docs/design-docs/active-agents-view.md
  // §"Runtime State Derivation"):
  //
  //  - onRunningPanesChanged: pane entered / left recomputes raw
  //    state. Progress only becomes raw `.working`
  //    after input has been seen for the bound agent, so process
  //    startup / first-screen loading stays idle. If a later
  //    transition moves from active to idle while the pane is not
  //    focused, the display state becomes `.finished`.
  //  - onTerminalEvent(.paneIdle): recompute raw state; if this is the
  //    first active → idle transition observed in the background, the
  //    display state becomes `.finished`.
  //  - onTerminalEvent(.paneExited | .paneCrashed | .paneClosedByTab):
  //    teardown — drop entry and scratch.
  //  - onTerminalEvent(.paneInfoChanged(.desktopNotification)): run
  //    `DetectionTranslator.classify`; .waitingForInput → set
  //    waitingForInput=true. .taskFinished is *not* mapped to finished
  //    here — finished is derived only from active → idle transitions.
  //  - onTerminalEvent(.paneInfoChanged(.bellRang)): treat the bell as
  //    a synthetic waitingForInput cue, matching the notifications
  //    detector (DetectionTranslator's bellRang branch).
  //  - onPaneKeyboardActivity / onPaneFocused: clear waitingForInput
  //    and mark the pane as seen.
  //  - onTerminalEvent(.paneInfoChanged(.title | .tabTitle)): append
  //    `now` to the per-pane title-event window; recompute. Loading
  //    surfaces only when the count inside `titleActivityWindow`
  //    crosses `titleActivityThreshold` — so a single sporadic
  //    redraw at the input prompt is harmless. A per-pane decay task
  //    re-checks once the window has elapsed so raw working falls back
  //    to idle even if no other event arrives.
  //  - onAgentBound: ensure scratch exists, derive current state,
  //    materialise an entry.
  //  - onAgentUnbound: drop entry and scratch.
  //
  // Deliberately NOT in the table: `paneOutput`. The libghostty
  // bridge does not currently forward subprocess bytes onto the
  // engine's output stream (see `PaneSurface.onOutput` — deferred),
  // so this event is effectively dead in production and would be a
  // spurious dependency to bind state on.

  /// Diff the running-panes set against the previous snapshot and
  /// react per the table above. Called from the engine-event drain
  /// each time the runtime publishes a new running-set.
  func onRunningPanesChanged(_ now: Set<PaneID>) {
    let entered = now.subtracting(lastRunning)
    let left = lastRunning.subtracting(now)
    lastRunning = now

    for paneID in entered {
      ensureScratch(paneID)
      refresh(paneID)
    }
    for paneID in left {
      ensureScratch(paneID)
      refresh(paneID)
    }
  }

  /// Single funnel for the runtime's typed event stream. The registry
  /// reacts only to a small subset (idle / teardown / notification /
  /// bell / title-rate); other cases are silent no-ops.
  func onTerminalEvent(_ event: TerminalEvent) {
    registryLogger.debug("onTerminalEvent \(Self.eventTag(event), privacy: .public)")
    switch event {
    case .paneIdle(let paneID, _):
      ensureScratch(paneID)
      refresh(paneID)

    case .paneExited(let paneID, _, _),
      .paneCrashed(let paneID, _),
      .paneClosedByTab(let paneID, _):
      // Teardown — registry forgets the pane entirely. Anything
      // downstream that wants to remember the last state should
      // snapshot before teardown.
      //
      // Dual-path contract: in production wiring, AgentBinder.unbind
      // also fires on every teardown event (see
      // `TouchCodeApp.dispatchToAgentBinder`) and routes through
      // `agentUnboundHandler → onAgentUnbound`, which already drops
      // entry + scratch for bound panes. By the time this branch
      // runs the entry is usually gone. This branch is still
      // load-bearing for callers that drive the registry directly
      // (tests, future non-binder consumers) without going through
      // AgentBinder. The redundant removeValue for an already-
      // unbound pane is a single `@Observable` no-op write.
      entries.removeValue(forKey: paneID)
      scratch.removeValue(forKey: paneID)
      lastRunning.remove(paneID)
      titleDecayTasks[paneID]?.cancel()
      titleDecayTasks.removeValue(forKey: paneID)

    case .paneInfoChanged(let paneID, let delta):
      switch delta {
      case .desktopNotification(let title, let body):
        // Reuse the notifications classifier so the two consumers
        // agree on what counts as "agent wants the user". Only
        // .waitingForInput maps to the sticky flag; .taskFinished is
        // ignored here — task-finished signalling for the runtime
        // state machine flows through paneIdle / runningPanes-exit.
        if DetectionTranslator.classify(title: title, body: body) == .waitingForInput {
          var s =
            scratch[paneID]
            ?? Scratch(
              rawState: .idle,
              seen: true,
              userInputSeen: false,
              waitingForInput: false,
              titleEventTimes: []
            )
          s.waitingForInput = true
          scratch[paneID] = s
          refresh(paneID)
        }

      case .bellRang:
        // Bell is treated as a waitingForInput cue, matching the
        // detector's bellRang branch. Same handling as a desktop
        // notification that classifies as waitingForInput.
        var s =
          scratch[paneID]
          ?? Scratch(
            rawState: .idle,
            seen: true,
            userInputSeen: false,
            waitingForInput: false,
            titleEventTimes: []
          )
        s.waitingForInput = true
        scratch[paneID] = s
        refresh(paneID)

      case .title, .tabTitle:
        // Append to the title-event window and recompute. The pane
        // surfaces as `.loading` only when the rate inside
        // `titleActivityWindow` clears `titleActivityThreshold`.
        recordTitleEvent(paneID: paneID)

      default:
        // pwd / mouse / progress / size etc. — not signals the
        // state machine cares about. (.progress feeds running-set
        // diffs via `TouchCodeApp.dispatchToAgentRegistry` wire 2,
        // not here.)
        break
      }

    case .paneOutput,
      .paneCreated, .paneReady,
      .tabActivated, .tabAutoClosed, .worktreeActivated, .hierarchyMutated,
      .paneActionRequested, .windowActionRequested, .configChanged:
      break
    }
  }

  /// The user typed into `paneID`. Clears the sticky `waitingForInput`
  /// flag and marks the pane as observed.
  func onPaneKeyboardActivity(_ paneID: PaneID) {
    guard var s = scratch[paneID] else { return }
    s.userInputSeen = true
    s.waitingForInput = false
    s.seen = true
    scratch[paneID] = s
    refresh(paneID)
  }

  /// `paneID` was focused. Same semantics as `onPaneKeyboardActivity`:
  /// the user has observed the pane, so clear display-only attention.
  func onPaneFocused(_ paneID: PaneID) {
    guard var s = scratch[paneID] else { return }
    s.waitingForInput = false
    s.seen = true
    scratch[paneID] = s
    refresh(paneID)
  }

  /// `AgentBinder` identified an agent in `paneID`. Materialise an
  /// entry and derive the initial state from any scratch already
  /// accumulated (the binder usually fires after `paneCreated` /
  /// `titleChanged`, by which point `paneOutput` may have arrived).
  func onAgentBound(_ paneID: PaneID, kind: AgentKind, sessionID: String?) {
    if scratch[paneID] == nil {
      scratch[paneID] = Scratch(
        rawState: .idle,
        seen: true,
        userInputSeen: false,
        waitingForInput: false,
        titleEventTimes: []
      )
    }
    refresh(paneID)
    let s = scratch[paneID]!
    let initialState = displayState(for: s)
    entries[paneID] = AgentEntry(
      kind: kind,
      sessionID: sessionID,
      state: initialState,
      lastTransitionAt: now()
    )
  }

  /// User-driven unbind path. Drops both the entry and its scratch so
  /// the row disappears from the popover and subsequent events for
  /// this pane become silent no-ops until something rebinds.
  func onAgentUnbound(_ paneID: PaneID) {
    entries.removeValue(forKey: paneID)
    scratch.removeValue(forKey: paneID)
    titleDecayTasks[paneID]?.cancel()
    titleDecayTasks.removeValue(forKey: paneID)
  }

  // MARK: - Derivation

  /// Raw state derivation. Display-only finished is intentionally not
  /// represented here; it is derived later from `seen`.
  private func deriveRawState(_ s: Scratch, isRunning: Bool) -> AgentRawState {
    if s.waitingForInput { return .blocked }
    guard s.userInputSeen else { return .idle }
    if isRunning || isTitleActivityActive(s) { return .working }
    return .idle
  }

  private func displayState(for s: Scratch) -> AgentRuntimeState {
    switch s.rawState {
    case .blocked:
      return .waitingForInput
    case .working:
      return .loading
    case .idle:
      return s.seen ? .idle : .finished
    }
  }

  /// True when the pane's title-event window contains at least
  /// `titleActivityThreshold` events whose timestamps are inside
  /// `titleActivityWindow` from `now()`. Comparison uses the injected
  /// `now` closure so tests stay deterministic.
  private func isTitleActivityActive(_ s: Scratch) -> Bool {
    let cutoff = now().addingTimeInterval(-Self.titleActivityWindow)
    let recent = s.titleEventTimes.filter { $0 > cutoff }
    return recent.count >= Self.titleActivityThreshold
  }

  /// Push a title / tabTitle event onto the per-pane window, trim
  /// stale entries, schedule the decay re-check, and recompute. The
  /// trim happens here (not lazily in `derive`) so the scratch
  /// doesn't grow unboundedly for a chatty agent.
  private func recordTitleEvent(paneID: PaneID) {
    var s =
      scratch[paneID]
      ?? Scratch(
        rawState: .idle,
        seen: true,
        userInputSeen: false,
        waitingForInput: false,
        titleEventTimes: []
      )
    let cutoff = now().addingTimeInterval(-Self.titleActivityWindow)
    s.titleEventTimes = s.titleEventTimes.filter { $0 > cutoff }
    s.titleEventTimes.append(now())
    scratch[paneID] = s
    scheduleTitleActivityDecay(for: paneID)
    refresh(paneID)
  }

  /// Replace (cancel + schedule) the per-pane decay task that fires
  /// once the rolling title-activity window has elapsed without a
  /// fresh delta. The fired task simply recomputes; if the windowed
  /// count has fallen below the threshold the pane falls out of
  /// `.loading` on its own.
  private func scheduleTitleActivityDecay(for paneID: PaneID) {
    titleDecayTasks[paneID]?.cancel()
    titleDecayTasks[paneID] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.titleActivityWindow + 0.05))
      guard let self, !Task.isCancelled else { return }
      self.decayTitleActivity(for: paneID)
    }
  }

  /// Called from the decay task. Re-evaluates the windowed title
  /// rate; if it has fallen below the threshold, raw state can move
  /// from working to idle and the display layer decides whether that
  /// idle state is already seen or should surface as `.finished`.
  private func decayTitleActivity(for paneID: PaneID) {
    guard var s = scratch[paneID] else { return }
    let cutoff = now().addingTimeInterval(-Self.titleActivityWindow)
    s.titleEventTimes = s.titleEventTimes.filter { $0 > cutoff }
    scratch[paneID] = s
    titleDecayTasks.removeValue(forKey: paneID)
    refresh(paneID)
  }

  private func isFocused(_ paneID: PaneID) -> Bool {
    focusedPane() == paneID
  }

  private func ensureScratch(_ paneID: PaneID) {
    if scratch[paneID] == nil {
      scratch[paneID] = Scratch(
        rawState: .idle,
        seen: true,
        userInputSeen: false,
        waitingForInput: false,
        titleEventTimes: []
      )
    }
  }

  /// Diagnostic tag — short shape-only string for the active log
  /// subsystem so we can see at a glance which event variants flow
  /// through onTerminalEvent without dragging the full enum payload
  /// (Data blobs, embedded structs) into the log stream.
  private static func eventTag(_ event: TerminalEvent) -> String {
    switch event {
    case .paneOutput(let id, _): return "paneOutput(\(id.raw.uuidString.prefix(8)))"
    case .paneIdle(let id, _): return "paneIdle(\(id.raw.uuidString.prefix(8)))"
    case .paneExited(let id, _, _): return "paneExited(\(id.raw.uuidString.prefix(8)))"
    case .paneCrashed(let id, _): return "paneCrashed(\(id.raw.uuidString.prefix(8)))"
    case .paneClosedByTab(let id, _): return "paneClosedByTab(\(id.raw.uuidString.prefix(8)))"
    case .paneInfoChanged(let id, let delta):
      return "paneInfoChanged(\(id.raw.uuidString.prefix(8)),\(deltaTag(delta)))"
    case .paneCreated(let id, _): return "paneCreated(\(id.raw.uuidString.prefix(8)))"
    case .paneReady(let id): return "paneReady(\(id.raw.uuidString.prefix(8)))"
    case .tabActivated: return "tabActivated"
    case .tabAutoClosed: return "tabAutoClosed"
    case .worktreeActivated: return "worktreeActivated"
    case .hierarchyMutated: return "hierarchyMutated"
    case .paneActionRequested: return "paneActionRequested"
    case .windowActionRequested: return "windowActionRequested"
    case .configChanged: return "configChanged"
    }
  }

  private static func deltaTag(_ delta: PaneInfoDelta) -> String {
    switch delta {
    case .title: return "title"
    case .tabTitle: return "tabTitle"
    case .desktopNotification: return "desktopNotification"
    case .bellRang: return "bellRang"
    case .progress: return "progress"
    default: return "other"
    }
  }

  /// Apply the latest raw + display derivation. Scratch is updated even
  /// when the pane is not bound yet so pre-bind signals still influence
  /// `onAgentBound`.
  private func refresh(_ paneID: PaneID) {
    guard var s = scratch[paneID] else { return }
    let isRunning = runningPanes().contains(paneID)
    let previousRaw = s.rawState
    let newRaw = deriveRawState(s, isRunning: isRunning)
    if isFocused(paneID) {
      s.seen = true
    } else if previousRaw.isActive, newRaw == .idle {
      s.seen = false
    }
    s.rawState = newRaw
    scratch[paneID] = s

    guard var entry = entries[paneID] else { return }
    let newState = displayState(for: s)
    guard entry.state != newState else { return }
    registryLogger.info(
      "state-transition pane=\(paneID.raw.uuidString, privacy: .public) \(entry.state.rawValue, privacy: .public)->\(newState.rawValue, privacy: .public)"
    )
    entry.state = newState
    entry.lastTransitionAt = now()
    entries[paneID] = entry
  }
}
