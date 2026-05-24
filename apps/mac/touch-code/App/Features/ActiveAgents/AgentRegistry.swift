import Foundation
import Observation
import OSLog
import TouchCodeCore

private let registryLogger = Logger(
  subsystem: "com.touch-code.activeagents", category: "registry"
)

/// Runtime-only state machine that derives each bound agent pane's
/// runtime state (`waitingForInput` / `loading` / `finished` / `idle`)
/// from the raw `TerminalEvent` stream plus keyboard / focus side
/// channels. Designed to be the single source of truth for the
/// ActiveAgents badge + popover (T5–T7). Nothing is persisted: every
/// entry is reconstructed from the live event flow at process start.
///
/// `entries` is keyed by `PaneID` and exposes one `AgentEntry` per
/// pane that has been bound via `onAgentBound(_:kind:sessionID:)`. The
/// dictionary is `@Observable`-tracked so SwiftUI consumers re-render
/// on every transition; every mutation writes the full entry struct
/// back to the subscript so change tracking fires reliably.
///
/// State priority (see `derive(...)`): `waitingForInput > loading >
/// finished > idle`. The waiting flag is sticky until the user
/// observably interacts (keystroke / focus). Loading is a live read
/// from the `runningPanes` closure. Finished is set when a previously-
/// loading pane goes quiet, either by leaving `runningPanes` or by
/// firing `paneIdle` while `prevPhase == .loading`. Idle is the
/// default fall-through.
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
  /// registry has heard about (bound or not) so a pane that fires
  /// `paneOutput` before its agent is identified still has the
  /// correct `prevPhase` when `onAgentBound` lands. Dropped on
  /// teardown / unbind.
  private struct Scratch {
    var prevPhase: PrevPhase
    var pendingFinished: Bool
    var waitingForInput: Bool
    /// Timestamp of the most recent `paneOutput` event. Drives
    /// output-driven loading for agents that don't emit OSC 9;4
    /// progress reports (Codex, pi, …): if output landed in the
    /// past `outputLoadingWindow`, the pane reads as `.loading`
    /// regardless of the `runningPanes` set. Cleared by the decay
    /// task when output goes quiet long enough.
    var lastOutputAt: Date?
  }

  /// Time window during which a recent `paneOutput` event keeps the
  /// pane in `.loading`. Picked to bridge typical inter-line gaps in
  /// agent output (Codex / pi emit chatty streams with brief pauses)
  /// while still letting the panel relax to idle within a few seconds
  /// of work actually stopping.
  private static let outputLoadingWindow: TimeInterval = 2.5

  /// Per-pane decay Task — fires `decayOutputLoading` after the
  /// `outputLoadingWindow` so the registry can transition out of
  /// output-driven loading even when no further runtime events arrive.
  /// Cancelled (or replaced) on every fresh `paneOutput` event.
  private var outputDecayTasks: [PaneID: Task<Void, Never>] = [:]

  private enum PrevPhase: Equatable {
    case idle
    case loading
  }

  private var scratch: [PaneID: Scratch] = [:]

  /// Snapshot of currently-running pane IDs (process attached + child
  /// alive). The registry samples this on every input.
  private let runningPanes: @MainActor () -> Set<PaneID>
  /// Globally focused pane, if any. Currently unused inside derivation
  /// (focus side-effects flow through `onPaneFocused`) but injected so
  /// future signals — e.g. "auto-clear waiting on focus regain" — can
  /// be added without changing the constructor.
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
  //  - onRunningPanesChanged: pane entered → prevPhase=.loading, clear
  //    pendingFinished; pane left → if prevPhase==.loading set
  //    pendingFinished=true, then prevPhase=.idle.
  //  - onTerminalEvent(.paneIdle): if prevPhase==.loading set
  //    pendingFinished=true (quiet-pane signal — no busy-clear, no
  //    output for ≥ idle threshold).
  //  - onTerminalEvent(.paneExited | .paneCrashed | .paneClosedByTab):
  //    teardown — drop entry and scratch.
  //  - onTerminalEvent(.paneOutput): clear pendingFinished; leave
  //    waitingForInput alone (agent may still be printing the prompt).
  //  - onTerminalEvent(.paneInfoChanged(.desktopNotification)): run
  //    `DetectionTranslator.classify`; .waitingForInput → set
  //    waitingForInput=true. .taskFinished is *not* mapped to
  //    pendingFinished here — that path belongs to the explicit
  //    running/idle transitions.
  //  - onTerminalEvent(.paneInfoChanged(.bellRang)): treat the bell as
  //    a synthetic waitingForInput cue, matching the notifications
  //    detector (DetectionTranslator's bellRang branch).
  //  - onPaneKeyboardActivity / onPaneFocused: clear waitingForInput
  //    *and* pendingFinished — both are "user has observed the pane".
  //  - onAgentBound: ensure scratch exists, derive current state,
  //    materialise an entry.
  //  - onAgentUnbound: drop entry and scratch.

  /// Diff the running-panes set against the previous snapshot and
  /// react per the table above. Called from the engine-event drain
  /// each time the runtime publishes a new running-set.
  func onRunningPanesChanged(_ now: Set<PaneID>) {
    let entered = now.subtracting(lastRunning)
    let left = lastRunning.subtracting(now)
    lastRunning = now

    for paneID in entered {
      var s =
        scratch[paneID]
        ?? Scratch(
          prevPhase: .idle, pendingFinished: false, waitingForInput: false, lastOutputAt: nil
        )
      s.prevPhase = .loading
      s.pendingFinished = false
      scratch[paneID] = s
      recompute(paneID)
    }
    for paneID in left {
      var s =
        scratch[paneID]
        ?? Scratch(
          prevPhase: .idle, pendingFinished: false, waitingForInput: false, lastOutputAt: nil
        )
      if s.prevPhase == .loading {
        s.pendingFinished = true
      }
      s.prevPhase = .idle
      scratch[paneID] = s
      recompute(paneID)
    }
  }

  /// Single funnel for the runtime's typed event stream. The registry
  /// reacts only to a small subset (output / idle / teardown / a few
  /// info deltas); other cases are silent no-ops.
  func onTerminalEvent(_ event: TerminalEvent) {
    switch event {
    case .paneOutput(let paneID, _):
      var s =
        scratch[paneID]
        ?? Scratch(
          prevPhase: .idle, pendingFinished: false, waitingForInput: false, lastOutputAt: nil
        )
      s.pendingFinished = false
      // Output-driven loading signal — see `outputLoadingWindow` doc.
      // Stamping every `paneOutput` arms the `.loading` state inside
      // `derive` and pushes the decay deadline forward.
      s.lastOutputAt = now()
      scratch[paneID] = s
      scheduleOutputDecay(for: paneID)
      registryLogger.debug(
        "paneOutput pane=\(paneID.raw.uuidString, privacy: .public) bound=\(self.entries[paneID] != nil, privacy: .public)"
      )
      recompute(paneID)

    case .paneIdle(let paneID, _):
      var s =
        scratch[paneID]
        ?? Scratch(
          prevPhase: .idle, pendingFinished: false, waitingForInput: false, lastOutputAt: nil
        )
      if s.prevPhase == .loading {
        s.pendingFinished = true
      }
      scratch[paneID] = s
      recompute(paneID)

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
      // load-bearing for two cases:
      //   1. Never-bound panes whose scratch accumulated from
      //      `paneOutput` between `paneCreated` and the first
      //      classification attempt — those never see the binder's
      //      unbind path and would leak `scratch` + `lastRunning`
      //      entries without this purge.
      //   2. Callers that drive the registry directly (tests,
      //      future non-binder consumers) without going through
      //      AgentBinder.
      // The redundant removeValue for an already-unbound pane is a
      // single `@Observable` no-op write — keeping it removes a
      // class of future regression where someone routes around the
      // binder and forgets the cleanup.
      entries.removeValue(forKey: paneID)
      scratch.removeValue(forKey: paneID)
      lastRunning.remove(paneID)
      outputDecayTasks[paneID]?.cancel()
      outputDecayTasks.removeValue(forKey: paneID)

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
            ?? Scratch(prevPhase: .idle, pendingFinished: false, waitingForInput: false)
          s.waitingForInput = true
          scratch[paneID] = s
          recompute(paneID)
        }

      case .bellRang:
        // Bell is treated as a waitingForInput cue, matching the
        // detector's bellRang branch. Same handling as a desktop
        // notification that classifies as waitingForInput.
        var s =
          scratch[paneID]
          ?? Scratch(prevPhase: .idle, pendingFinished: false, waitingForInput: false)
        s.waitingForInput = true
        scratch[paneID] = s
        recompute(paneID)

      default:
        // Title / pwd / mouse / progress etc. — not signals the state
        // machine cares about.
        break
      }

    case .paneCreated, .paneReady,
      .tabActivated, .tabAutoClosed, .worktreeActivated, .hierarchyMutated,
      .paneActionRequested, .windowActionRequested, .configChanged:
      break
    }
  }

  /// The user typed into `paneID`. Clears the sticky `waitingForInput`
  /// flag and any pending finished state — both are "user is engaged
  /// with this pane".
  func onPaneKeyboardActivity(_ paneID: PaneID) {
    guard var s = scratch[paneID] else { return }
    s.waitingForInput = false
    s.pendingFinished = false
    scratch[paneID] = s
    recompute(paneID)
  }

  /// `paneID` was focused. Same semantics as `onPaneKeyboardActivity`:
  /// the user has observed the pane, so clear any "needs your
  /// attention" signalling.
  func onPaneFocused(_ paneID: PaneID) {
    guard var s = scratch[paneID] else { return }
    s.waitingForInput = false
    s.pendingFinished = false
    scratch[paneID] = s
    recompute(paneID)
  }

  /// `AgentBinder` identified an agent in `paneID`. Materialise an
  /// entry and derive the initial state from any scratch already
  /// accumulated (the binder usually fires after `paneCreated` /
  /// `titleChanged`, by which point `paneOutput` may have arrived).
  func onAgentBound(_ paneID: PaneID, kind: AgentKind, sessionID: String?) {
    if scratch[paneID] == nil {
      scratch[paneID] = Scratch(prevPhase: .idle, pendingFinished: false, waitingForInput: false)
    }
    let isRunning = runningPanes().contains(paneID)
    let initialState = derive(paneID: paneID, isRunning: isRunning)
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
    outputDecayTasks[paneID]?.cancel()
    outputDecayTasks.removeValue(forKey: paneID)
  }

  // MARK: - Derivation

  /// Pure mapping from scratch + live `isRunning` to the surfaced
  /// runtime state. Priority is `waitingForInput > loading > finished
  /// > idle`; getting this order wrong silently mis-renders the
  /// badge (T6).
  private func derive(paneID: PaneID, isRunning: Bool) -> AgentRuntimeState {
    let s =
      scratch[paneID]
        ?? Scratch(
          prevPhase: .idle, pendingFinished: false, waitingForInput: false, lastOutputAt: nil
        )
    if s.waitingForInput { return .waitingForInput }
    // Loading from either signal: OSC 9;4 busy (Claude Code) OR a
    // recent paneOutput (Codex / pi / anything else that doesn't
    // emit OSC 9;4). The output window is short so output bursts
    // bridge gaps but quiet panes flip back to idle.
    if isRunning || isOutputLoadingActive(s) { return .loading }
    if s.pendingFinished { return .finished }
    return .idle
  }

  /// True when `lastOutputAt` is within the output-loading window.
  /// Comparison uses the injected `now` closure so tests stay
  /// deterministic.
  private func isOutputLoadingActive(_ s: Scratch) -> Bool {
    guard let lastOutput = s.lastOutputAt else { return false }
    return now().timeIntervalSince(lastOutput) < Self.outputLoadingWindow
  }

  /// Replace (cancel + schedule) the per-pane decay task that fires
  /// once the output-loading window has elapsed without a fresh
  /// `paneOutput`. The fired task calls `decayOutputLoading(_:)` which
  /// arms `pendingFinished` (mirroring the running-set-leave
  /// transition for OSC 9;4 agents) and clears `lastOutputAt`.
  private func scheduleOutputDecay(for paneID: PaneID) {
    outputDecayTasks[paneID]?.cancel()
    outputDecayTasks[paneID] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.outputLoadingWindow + 0.05))
      guard let self, !Task.isCancelled else { return }
      self.decayOutputLoading(for: paneID)
    }
  }

  /// Called from the decay task when the output-loading window has
  /// elapsed. Defensive against races: a `paneOutput` that arrived
  /// between the sleep and the wake re-stamps `lastOutputAt`, so the
  /// elapsed-window check stays the source of truth.
  private func decayOutputLoading(for paneID: PaneID) {
    guard var s = scratch[paneID], let lastOutput = s.lastOutputAt else { return }
    let elapsed = now().timeIntervalSince(lastOutput)
    guard elapsed >= Self.outputLoadingWindow else { return }
    // Output-driven loading just ended — mirror the running-set-leave
    // transition (`pendingFinished` so the next focus / keystroke /
    // new output flips back to idle, or paneIdle / teardown surfaces
    // `.finished` if no user action arrives).
    s.pendingFinished = true
    s.lastOutputAt = nil
    scratch[paneID] = s
    outputDecayTasks.removeValue(forKey: paneID)
    recompute(paneID)
  }

  /// Apply the latest derivation to `entries[paneID]`. No-op when the
  /// pane is not bound (scratch may be live without a corresponding
  /// entry). Writes the full struct back via subscript so
  /// `@Observable` change tracking fires; skips the write when the
  /// derived state hasn't changed so we don't churn `lastTransitionAt`.
  private func recompute(_ paneID: PaneID) {
    guard var entry = entries[paneID] else { return }
    let isRunning = runningPanes().contains(paneID)
    let newState = derive(paneID: paneID, isRunning: isRunning)
    guard entry.state != newState else { return }
    registryLogger.info(
      "state-transition pane=\(paneID.raw.uuidString, privacy: .public) \(entry.state.rawValue, privacy: .public)->\(newState.rawValue, privacy: .public)"
    )
    entry.state = newState
    entry.lastTransitionAt = now()
    entries[paneID] = entry
  }
}
