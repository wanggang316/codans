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
/// attention bit. Raw state comes from the rendered viewport plus bell /
/// notification side channels.
/// Designed to be the single source of truth for the ActiveAgents badge +
/// popover (T5–T7). Nothing is persisted: every entry is reconstructed
/// from the live event flow at process start.
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
/// observed user input and its viewport matches an agent-specific
/// working cue.
/// Finished is not a raw state: it is the display form of a pane that
/// moved from active raw state back to idle while the user was not looking
/// at it.
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
    var lastViewportText: String?
    var lastWorkingAt: Date?

    static func fresh(userInputSeen: Bool = false) -> Self {
      Self(
        rawState: .idle,
        seen: true,
        userInputSeen: userInputSeen,
        waitingForInput: false,
        lastViewportText: nil,
        lastWorkingAt: nil
      )
    }
  }

  private typealias AgentRawState = PaneAttentionInterpreter.AgentActivityState

  private var scratch: [PaneID: Scratch] = [:]

  /// Globally focused pane, if any. Used to avoid surfacing
  /// `.finished` for work the user is already looking at; focus
  /// change events still clear a previously surfaced finished state.
  private let focusedPane: @MainActor () -> PaneID?
  /// Time source. Injected so tests can assert on `lastTransitionAt`
  /// without racing real `Date()`.
  private let now: () -> Date

  init(
    focusedPane: @escaping @MainActor () -> PaneID?,
    now: @escaping () -> Date = Date.init
  ) {
    self.focusedPane = focusedPane
    self.now = now
  }

  // MARK: - Inputs
  //
  // Reaction table (see docs/design-docs/active-agents-view.md
  // §"Runtime State Derivation"):
  //
  //  - onTerminalEvent(.paneViewportChanged): classify the rendered
  //    viewport through `PaneAttentionInterpreter`'s agent-specific
  //    rules. Process identity decides which agent this is; viewport
  //    content decides whether it is working, blocked, or idle.
  //  - onTerminalEvent(.paneIdle): recompute raw state; if this is the
  //    first active → idle transition observed in the background, the
  //    display state becomes `.finished`.
  //  - onTerminalEvent(.paneExited | .paneCrashed | .paneClosedByTab):
  //    teardown — drop entry and scratch.
  //  - onTerminalEvent(.paneInfoChanged(.desktopNotification)): run
  //    `PaneAttentionInterpreter.classify`; .waitingForInput → set
  //    waitingForInput=true. .taskFinished is *not* mapped to finished
  //    here — finished is derived only from active → idle transitions.
  //  - onTerminalEvent(.paneInfoChanged(.bellRang)): treat the bell as
  //    a synthetic waitingForInput cue, matching the notifications
  //    detector (PaneAttentionInterpreter's bellRang branch).
  //  - onPaneKeyboardActivity / onPaneFocused: clear waitingForInput
  //    and mark the pane as seen.
  //  - onAgentBound: ensure scratch exists, derive current state,
  //    materialise an entry.
  //  - onAgentUnbound: drop entry and scratch.
  //
  // Deliberately NOT in the table: `paneOutput`. The state machine reads
  // stable viewport snapshots instead of raw byte output so TUI repaint
  // noise cannot pin a pane on `.loading`.

  /// Single funnel for the runtime's typed event stream. The registry
  /// reacts only to a small subset (idle / teardown / notification /
  /// bell); other cases are silent no-ops.
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

    case .paneInfoChanged(let paneID, let delta):
      switch delta {
      case .desktopNotification, .bellRang:
        applyWaitingCueIfNeeded(from: event, paneID: paneID)

      default:
        // pwd / mouse / progress / size etc. are not signals the
        // state machine cares about.
        break
      }

    case .paneViewportChanged(let paneID, let text):
      applyViewportText(text, paneID: paneID)

    case .paneOutput,
      .foregroundJobChanged,
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
    if s.waitingForInput {
      s.lastViewportText = nil
    }
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
    if s.waitingForInput {
      s.lastViewportText = nil
    }
    s.waitingForInput = false
    s.seen = true
    scratch[paneID] = s
    refresh(paneID)
  }

  /// `AgentBinder` identified an agent in `paneID`. Materialise an
  /// entry and derive the initial state from any scratch already
  /// accumulated before the foreground job is identified.
  func onAgentBound(
    _ paneID: PaneID,
    kind: AgentKind,
    sessionID: String?,
    assumeUserInputSeen: Bool = false
  ) {
    if var existing = scratch[paneID] {
      existing.userInputSeen = existing.userInputSeen || assumeUserInputSeen
      scratch[paneID] = existing
    } else {
      scratch[paneID] = .fresh(userInputSeen: assumeUserInputSeen)
    }
    entries[paneID] = AgentEntry(
      kind: kind,
      sessionID: sessionID,
      state: .idle,
      lastTransitionAt: now()
    )
    refresh(paneID)
  }

  /// User-driven unbind path. Drops both the entry and its scratch so
  /// the row disappears from the popover and subsequent events for
  /// this pane become silent no-ops until something rebinds.
  func onAgentUnbound(_ paneID: PaneID) {
    entries.removeValue(forKey: paneID)
    scratch.removeValue(forKey: paneID)
  }

  // MARK: - Derivation

  /// Raw state derivation. Display-only finished is intentionally not
  /// represented here; it is derived later from `seen`.
  private func deriveRawState(_ s: Scratch, kind: AgentKind?) -> AgentRawState {
    if s.waitingForInput { return .blocked }
    guard let kind, let text = s.lastViewportText else { return .idle }
    let raw = PaneAttentionInterpreter.classifyAgentActivity(kind: kind, viewportText: text)
    if raw == .blocked { return .blocked }
    return s.userInputSeen ? raw : .idle
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

  private func isFocused(_ paneID: PaneID) -> Bool {
    focusedPane() == paneID
  }

  private func ensureScratch(_ paneID: PaneID) {
    if scratch[paneID] == nil {
      scratch[paneID] = .fresh()
    }
  }

  private func applyViewportText(_ text: String, paneID: PaneID) {
    var s = scratch[paneID] ?? .fresh()
    s.lastViewportText = text
    scratch[paneID] = s
    refresh(paneID)
  }

  private func applyWaitingCueIfNeeded(from event: TerminalEvent, paneID: PaneID) {
    let step = PaneAttentionInterpreter.interpret(
      event,
      context: PaneAttentionInterpreter.Context(
        hasProducedOutput: [],
        commandFinishedEnabled: false
      )
    )
    guard step.cue?.kind == .waitingForInput else { return }
    var s = scratch[paneID] ?? .fresh()
    s.waitingForInput = true
    scratch[paneID] = s
    refresh(paneID)
  }

  /// Diagnostic tag — short shape-only string for the active log
  /// subsystem so we can see at a glance which event variants flow
  /// through onTerminalEvent without dragging the full enum payload
  /// (Data blobs, embedded structs) into the log stream.
  private static func eventTag(_ event: TerminalEvent) -> String {
    switch event {
    case .paneOutput(let id, _): return "paneOutput(\(id.raw.uuidString.prefix(8)))"
    case .paneViewportChanged(let id, _):
      return "paneViewportChanged(\(id.raw.uuidString.prefix(8)))"
    case .paneIdle(let id, _): return "paneIdle(\(id.raw.uuidString.prefix(8)))"
    case .paneExited(let id, _, _): return "paneExited(\(id.raw.uuidString.prefix(8)))"
    case .paneCrashed(let id, _): return "paneCrashed(\(id.raw.uuidString.prefix(8)))"
    case .paneClosedByTab(let id, _): return "paneClosedByTab(\(id.raw.uuidString.prefix(8)))"
    case .paneInfoChanged(let id, let delta):
      return "paneInfoChanged(\(id.raw.uuidString.prefix(8)),\(deltaTag(delta)))"
    case .foregroundJobChanged(let id, _): return "foregroundJobChanged(\(id.raw.uuidString.prefix(8)))"
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
    let kind = entries[paneID]?.kind
    let previousRaw = s.rawState
    var newRaw = deriveRawState(s, kind: kind)
    if let kind {
      newRaw = PaneAttentionInterpreter.stabilizeAgentActivity(
        kind: kind,
        previous: previousRaw,
        raw: newRaw,
        now: now(),
        lastWorkingAt: &s.lastWorkingAt
      )
    }
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
