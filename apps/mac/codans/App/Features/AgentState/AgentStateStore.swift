import CodansCore
import Foundation
import OSLog
import Observation

private let storeLogger = Logger(
  subsystem: "com.gumpw.codans.agentstate", category: "store"
)

/// Runtime-only state machine that derives each bound agent pane's
/// runtime state (`idle` / `working` / `blocked` / `finished`) from the
/// raw `working` / `blocked` / `idle` classifier plus an observed/
/// unobserved attention bit. Raw state comes from the rendered active
/// region; `finished` is the display form of an unobserved completion.
/// Designed to be the single source of truth for the AgentState badge +
/// view. Nothing is persisted: every entry is reconstructed from the
/// live event flow at process start.
///
/// `entries` is keyed by `PaneID` and exposes one `AgentEntry` per
/// pane that has been bound via `onAgentBound(_:kind:sessionID:)`. The
/// dictionary is `@Observable`-tracked so SwiftUI consumers re-render
/// on every transition; every mutation writes the full entry struct
/// back to the subscript so change tracking fires reliably.
///
/// Display priority is `blocked > working > finished > idle`.
/// A blocked raw state clears when the user observably interacts
/// (keystroke / focus). Working fires only after the bound agent has
/// observed user input and its rendered region matches an agent-specific
/// working cue.
/// Finished is not a raw state: it is the display form of a pane that
/// moved from an active raw state back to idle while the user was not
/// looking at it.
///
/// Lifecycle teardown (`paneExited` / `paneCrashed` / `paneClosedByTab`)
/// drops both the entry and its scratch — the row disappears from the
/// view when the user closes the pane. `onAgentUnbound` does the same
/// explicitly for the user-driven unbind path. `reconcileMembership`
/// is the catalog backstop for a pane that leaves the hierarchy without
/// delivering one of those events. The store is silently inert for
/// unbound panes: events arrive, scratch stays uninitialized, and
/// `entries` never grows.
@MainActor
@Observable
final class AgentStateStore {
  /// One row in the store. Pane-keyed via `entries`. `state` and
  /// `lastTransitionAt` are mutated in place; `kind` and `sessionID`
  /// are immutable for the entry's lifetime (rebind requires
  /// `onAgentUnbound` followed by `onAgentBound`).
  struct AgentEntry: Equatable {
    let kind: AgentKind
    let sessionID: String?
    var state: AgentRuntimeState
    var lastTransitionAt: Date
  }

  /// Derived runtime state surfaced to UI. Shares its vocabulary with the
  /// raw `AgentActivityState` classifier (`working` / `blocked` / `idle`)
  /// and adds `finished` for an unobserved completion, so no state has to
  /// be renamed as it flows from classifier to UI. Distinct from the
  /// inbox-side `InboxEntry.Kind`, which tracks notification events rather
  /// than live activity.
  enum AgentRuntimeState: String, CaseIterable, Equatable, Sendable {
    case idle
    case working
    case blocked
    case finished
  }

  /// Public, read-only view of bound agents. `@Observable` tracks
  /// dictionary subscript writes so SwiftUI consumers re-render on
  /// every state transition.
  private(set) var entries: [PaneID: AgentEntry] = [:]

  /// Per-pane derivation scratch. Kept around for all panes the
  /// store has heard about (bound or not) so signals that arrive
  /// before an agent is identified still leave the correct raw state
  /// and observation state when `onAgentBound` lands. Dropped on
  /// teardown / unbind.
  private struct Scratch {
    var rawState: AgentRawState
    var seen: Bool
    var userInputSeen: Bool
    var lastViewportText: String?
    var lastWorkingAt: Date?
    /// True only for a pane seeded from the persisted quit snapshot that
    /// has not yet received a live viewport classification. While set,
    /// `refresh` holds the restored display state instead of deriving a
    /// synthetic `.idle` from the (still-absent) viewport text — otherwise
    /// the `onAgentBound` rebind at launch would collapse a resumed
    /// working/blocked badge. Cleared the instant a real viewport lands
    /// (`applyViewportText`).
    var awaitingFirstClassification: Bool

    static func fresh(
      userInputSeen: Bool = false,
      awaitingFirstClassification: Bool = false
    ) -> Self {
      Self(
        rawState: .idle,
        seen: true,
        userInputSeen: userInputSeen,
        lastViewportText: nil,
        lastWorkingAt: nil,
        awaitingFirstClassification: awaitingFirstClassification
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
  // Reaction table:
  //
  //  - onTerminalEvent(.paneViewportChanged): classify the rendered
  //    active region through `PaneAttentionInterpreter`'s agent-specific
  //    rules. Process identity decides which agent this is; the rendered
  //    content decides whether it is working, blocked, or idle. This is
  //    the *only* source of `.blocked` / `.working`.
  //  - onTerminalEvent(.paneIdle): recompute raw state; if this is the
  //    first active → idle transition observed in the background, the
  //    display state becomes `.finished`.
  //  - onTerminalEvent(.paneExited | .paneCrashed | .paneClosedByTab):
  //    teardown — drop entry and scratch.
  //  - onPaneKeyboardActivity / onPaneFocused: mark the pane as seen and
  //    optimistically clear a blocked state until the next snapshot
  //    re-derives it.
  //  - onAgentBound: ensure scratch exists, derive current state,
  //    materialise an entry.
  //  - onAgentUnbound: drop entry and scratch.
  //
  // Deliberately NOT in the table: `paneOutput`, and `paneInfoChanged`'s
  // desktopNotification / bellRang deltas. A bell or OS notification is an
  // inbox-worthy *event* but not a live activity signal — the agent's
  // current working/blocked/idle state is whatever the rendered region
  // says right now, so the notifications detector consumes those deltas
  // independently while this store stays purely render-derived. Reading
  // stable snapshots instead of raw byte output also keeps TUI repaint
  // noise from pinning a pane on `.working`.

  /// Single funnel for the runtime's typed event stream. The store
  /// reacts only to a small subset (viewport / idle / teardown); other
  /// cases are silent no-ops.
  func onTerminalEvent(_ event: TerminalEvent) {
    storeLogger.debug("onTerminalEvent \(Self.eventTag(event), privacy: .public)")
    switch event {
    case .paneIdle(let paneID, _):
      ensureScratch(paneID)
      refresh(paneID)

    case .paneExited(let paneID, _, _),
      .paneCrashed(let paneID, _),
      .paneClosedByTab(let paneID, _):
      // Teardown — store forgets the pane entirely. Anything
      // downstream that wants to remember the last state should
      // snapshot before teardown.
      //
      // Dual-path contract: in production wiring, AgentBinder.unbind
      // also fires on every teardown event (see
      // `CodansApp.dispatchToAgentBinder`) and routes through
      // `agentUnboundHandler → onAgentUnbound`, which already drops
      // entry + scratch for bound panes. By the time this branch
      // runs the entry is usually gone. This branch is still
      // load-bearing for callers that drive the store directly
      // (tests, future non-binder consumers) without going through
      // AgentBinder. The redundant removeValue for an already-
      // unbound pane is a single `@Observable` no-op write.
      entries.removeValue(forKey: paneID)
      scratch.removeValue(forKey: paneID)

    case .paneViewportChanged(let paneID, let text):
      applyViewportText(text, paneID: paneID)

    case .paneInfoChanged,
      .paneOutput,
      .foregroundJobChanged,
      .paneCreated, .paneReady,
      .tabActivated, .tabAutoClosed, .worktreeActivated, .hierarchyMutated,
      .paneActionRequested, .windowActionRequested, .configChanged:
      break
    }
  }

  /// The user typed into `paneID`. Marks the pane as observed and
  /// optimistically clears a blocked state — the user is responding to the
  /// prompt, so drop the attention cue until the next snapshot re-derives it.
  func onPaneKeyboardActivity(_ paneID: PaneID) {
    guard var s = scratch[paneID] else { return }
    if s.rawState == .blocked {
      s.lastViewportText = nil
      s.lastWorkingAt = nil
      s.rawState = .idle
    }
    s.userInputSeen = true
    s.seen = true
    scratch[paneID] = s
    refresh(paneID)
  }

  /// `paneID` was focused. Same semantics as `onPaneKeyboardActivity`:
  /// the user has observed the pane, so clear display-only attention.
  func onPaneFocused(_ paneID: PaneID) {
    guard var s = scratch[paneID] else { return }
    if s.rawState == .blocked {
      s.lastViewportText = nil
      s.lastWorkingAt = nil
      s.rawState = .idle
    }
    s.seen = true
    scratch[paneID] = s
    refresh(paneID)
  }

  /// `AgentBinder` identified an agent in `paneID`. Materialise an
  /// entry and derive the initial state from any scratch already
  /// accumulated before the foreground job is identified.
  ///
  /// If a viewport snapshot already classifies as `.working` or `.blocked`
  /// for the bound kind, treat it as user-input observed. This catches
  /// the "agent was already running when the binding formed" case (a fresh
  /// pane that an external trigger spawned with an immediately-running
  /// agent) so the badge surfaces the classifier output instead of staying
  /// `.idle` until the user types. The app-restart case is handled
  /// separately by the persisted seed (see `seedRestored`), preserved below.
  func onAgentBound(
    _ paneID: PaneID,
    kind: AgentKind,
    sessionID: String?,
    assumeUserInputSeen: Bool = false
  ) {
    let viewportImpliesActive: Bool = {
      guard let text = scratch[paneID]?.lastViewportText else { return false }
      let raw = PaneAttentionInterpreter.classifyAgentActivity(kind: kind, viewportText: text)
      return raw == .working || raw == .blocked
    }()
    let effectiveUserInputSeen = assumeUserInputSeen || viewportImpliesActive

    if var existing = scratch[paneID] {
      existing.userInputSeen = existing.userInputSeen || effectiveUserInputSeen
      scratch[paneID] = existing
    } else {
      scratch[paneID] = .fresh(userInputSeen: effectiveUserInputSeen)
    }
    // Preserve a state seeded from the persisted quit snapshot
    // (`seedRestored`). The binder re-identifies the restored agent and
    // calls this on launch; hardcoding `.idle` here dropped the resumed
    // working/blocked badge before any live viewport arrived. Fresh
    // bindings have no prior entry and correctly start `.idle`.
    let seeded = entries[paneID]
    entries[paneID] = AgentEntry(
      kind: kind,
      sessionID: sessionID,
      state: seeded?.state ?? .idle,
      lastTransitionAt: seeded?.lastTransitionAt ?? now()
    )
    refresh(paneID)
  }

  /// User-driven unbind path. Drops both the entry and its scratch so
  /// the row disappears from the view and subsequent events for
  /// this pane become silent no-ops until something rebinds.
  func onAgentUnbound(_ paneID: PaneID) {
    entries.removeValue(forKey: paneID)
    scratch.removeValue(forKey: paneID)
  }

  /// Catalog-membership backstop. Drops every entry (and its scratch)
  /// whose pane is no longer present in the live catalog.
  ///
  /// Bound entries are normally retired by the per-pane teardown events
  /// (`paneExited` / `paneCrashed` / `paneClosedByTab`) or `onAgentUnbound`,
  /// but a pane can leave the hierarchy without one reaching the store — a
  /// worktree / project removal, or a launch seed for a pane the catalog no
  /// longer hosts. Such an entry can never resolve to a project/worktree, so
  /// `AgentStateView` renders it as an em-dash "ghost" row; left alone it is
  /// re-persisted into the quit snapshot and liveness-seeded again next
  /// launch. Reconciling against the live catalog on every structural
  /// mutation breaks that loop. Driven by the app's event drain on
  /// `hierarchyMutated` (see `AppState.dispatchToAgentStateStore`).
  ///
  /// Takes a flat `Set<PaneID>` rather than a `Catalog` so the store stays
  /// free of hierarchy imports — the catalog walk lives in the wiring layer.
  func reconcileMembership(livePaneIDs: Set<PaneID>) {
    let stale = entries.keys.filter { !livePaneIDs.contains($0) }
    guard !stale.isEmpty else { return }
    for paneID in stale {
      storeLogger.info(
        "reconcile-drop pane=\(paneID.raw.uuidString, privacy: .public) — absent from catalog"
      )
      entries.removeValue(forKey: paneID)
      scratch.removeValue(forKey: paneID)
    }
  }

  /// Pre-seed the registry from a persisted catalog at launch. Each
  /// record contributes one `AgentEntry` so the ActiveAgents UI shows
  /// the correct state immediately rather than starting empty and
  /// catching up after the first viewport refresh. Unknown enum raws
  /// (kind or state added in a future build) are skipped silently —
  /// dropping a stale row is preferable to crashing the launch.
  ///
  /// Scratch is initialised with `userInputSeen = true` so the
  /// restored state cannot be flipped to a synthetic "finished" cue
  /// before any user interaction; the next real event refines it.
  func seedRestored(_ records: [(paneID: PaneID, kind: AgentKind, state: AgentRuntimeState)]) {
    for record in records {
      entries[record.paneID] = AgentEntry(
        kind: record.kind,
        sessionID: nil,
        state: record.state,
        lastTransitionAt: now()
      )
      scratch[record.paneID] = .fresh(
        userInputSeen: true,
        awaitingFirstClassification: true
      )
    }
  }

  // MARK: - Derivation

  /// Raw state derivation. Display-only finished is intentionally not
  /// represented here; it is derived later from `seen`.
  private func deriveRawState(_ s: Scratch, kind: AgentKind?) -> AgentRawState {
    guard let kind, let text = s.lastViewportText else { return .idle }
    let raw = PaneAttentionInterpreter.classifyAgentActivity(kind: kind, viewportText: text)
    if raw == .blocked { return .blocked }
    return s.userInputSeen ? raw : .idle
  }

  private func displayState(for s: Scratch) -> AgentRuntimeState {
    switch s.rawState {
    case .blocked:
      return .blocked
    case .working:
      return .working
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
    // A real viewport classification now governs; release the restored
    // seed so normal derivation takes over (see `seedRestored`).
    s.awaitingFirstClassification = false
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

    // A pane seeded from the quit snapshot holds its restored display
    // state until the first live viewport classification — deriving from
    // absent viewport text would collapse a resumed working/blocked badge
    // to idle. `applyViewportText` clears the flag the moment real output
    // lands, handing control back to normal derivation.
    if s.awaitingFirstClassification { return }

    guard var entry = entries[paneID] else { return }
    let newState = displayState(for: s)
    guard entry.state != newState else { return }
    storeLogger.info(
      "state-transition pane=\(paneID.raw.uuidString, privacy: .public) \(entry.state.rawValue, privacy: .public)->\(newState.rawValue, privacy: .public)"
    )
    entry.state = newState
    entry.lastTransitionAt = now()
    entries[paneID] = entry
  }
}
