import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Behavioural coverage for `AgentRegistry`'s state machine. The
/// registry derives each bound agent pane's runtime state from a few
/// event channels (running set, terminal events, keystroke / focus,
/// explicit bind / unbind); these tests pin down the table in the
/// design doc — every transition that T5 / T6 will rely on to render
/// the ActiveAgents badge + popover.
///
/// The fixture mirrors `AgentBinderTests`: a `LockIsolated<Set<PaneID>>`
/// stands in for the runtime's running-pane set so `runningPanes` and
/// `focusedPane` closures read against test-controlled state. `now`
/// is driven by an injected counter so `lastTransitionAt` is
/// deterministic.
@MainActor
struct AgentRegistryStateTests {
  /// (1) Only `onAgentBound` → state `.idle`. No running, no signals.
  @Test
  func boundOnlyYieldsIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  /// (2) After bound, `onRunningPanesChanged([paneID])` → `.loading`.
  @Test
  func runningPanesEnteringDrivesLoading() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.running.setValue([f.paneID])
    f.registry.onRunningPanesChanged([f.paneID])
    #expect(f.registry.entries[f.paneID]?.state == .loading)
  }

  /// (3) After `.loading`, `onRunningPanesChanged([])` → `.finished`.
  @Test
  func runningPanesLeavingDrivesFinished() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.running.setValue([f.paneID])
    f.registry.onRunningPanesChanged([f.paneID])
    f.running.setValue([])
    f.registry.onRunningPanesChanged([])
    #expect(f.registry.entries[f.paneID]?.state == .finished)
  }

  /// (4) From `.finished`, the running set re-entering (a fresh
  /// OSC 9;4 busy report) clears `pendingFinished` and flips the
  /// pane back to `.loading`. `paneOutput` and title heartbeats no
  /// longer drive transitions — OSC 9;4 is the sole "working"
  /// signal, so the cycle is fully self-healing through the
  /// running-set channel without needing a separate output-based
  /// nudge.
  @Test
  func runningPanesReEnteringClearsFinishedBackToLoading() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.running.setValue([f.paneID])
    f.registry.onRunningPanesChanged([f.paneID])
    f.running.setValue([])
    f.registry.onRunningPanesChanged([])
    #expect(f.registry.entries[f.paneID]?.state == .finished)

    f.running.setValue([f.paneID])
    f.registry.onRunningPanesChanged([f.paneID])
    #expect(f.registry.entries[f.paneID]?.state == .loading)
  }

  /// (4b) `paneOutput` is intentionally not a state signal: a
  /// `.finished` pane stays `.finished` when raw output arrives.
  /// TUI agents (and even shell-mode agents painting their prompt)
  /// stream output for non-work reasons; treating it as activity
  /// pinned the registry on `.loading` while the user was sitting
  /// at an input prompt.
  @Test
  func paneOutputDoesNotChangeFinishedState() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.running.setValue([f.paneID])
    f.registry.onRunningPanesChanged([f.paneID])
    f.running.setValue([])
    f.registry.onRunningPanesChanged([])
    #expect(f.registry.entries[f.paneID]?.state == .finished)

    f.registry.onTerminalEvent(.paneOutput(f.paneID, Data()))
    #expect(f.registry.entries[f.paneID]?.state == .finished)
  }

  /// (4c) A single title delta is not enough to flip the row —
  /// sporadic redraws at the input prompt (cursor moves, focus
  /// restore, manual rename) must not register as "working". The
  /// rate gate requires the windowed count to clear
  /// `titleActivityThreshold`.
  @Test
  func singleTitleDeltaDoesNotChangeIdleState() {
    let clock = LockIsolated<Date>(Date(timeIntervalSince1970: 1_000))
    let running = LockIsolated<Set<PaneID>>([])
    let registry = AgentRegistry(
      runningPanes: { running.value },
      focusedPane: { nil },
      now: { clock.value }
    )
    let paneID = PaneID()
    registry.onAgentBound(paneID, kind: .claudeCode, sessionID: nil)
    #expect(registry.entries[paneID]?.state == .idle)

    registry.onTerminalEvent(.paneInfoChanged(paneID, .title("claude-code")))
    #expect(registry.entries[paneID]?.state == .idle)

    // A second event still inside the window but still under the
    // threshold (which is ≥ 3 by current tuning) — still idle.
    clock.setValue(Date(timeIntervalSince1970: 1_000.5))
    registry.onTerminalEvent(.paneInfoChanged(paneID, .tabTitle("● claude-code")))
    #expect(registry.entries[paneID]?.state == .idle)
  }

  /// (4d) Title-rate above threshold inside the window flips the
  /// row to `.loading`. Covers the long thinking / streaming
  /// stretches in TUI agents that do not emit OSC 9;4 outside of
  /// explicit tool calls — the status spinner / token counter / phase
  /// label all update fast enough to clear the bar.
  @Test
  func titleRateAboveThresholdDrivesLoading() {
    let clock = LockIsolated<Date>(Date(timeIntervalSince1970: 1_000))
    let running = LockIsolated<Set<PaneID>>([])
    let registry = AgentRegistry(
      runningPanes: { running.value },
      focusedPane: { nil },
      now: { clock.value }
    )
    let paneID = PaneID()
    registry.onAgentBound(paneID, kind: .claudeCode, sessionID: nil)

    // Three title events inside a 2s window — clears the rate gate.
    registry.onTerminalEvent(.paneInfoChanged(paneID, .title("✶ Thinking")))
    clock.setValue(Date(timeIntervalSince1970: 1_000.5))
    registry.onTerminalEvent(.paneInfoChanged(paneID, .title("✶ Thinking (10k)")))
    clock.setValue(Date(timeIntervalSince1970: 1_001.0))
    registry.onTerminalEvent(.paneInfoChanged(paneID, .title("✶ Thinking (20k)")))

    #expect(registry.entries[paneID]?.state == .loading)
  }

  /// (4e) Title rate decay: once title events stop, advancing time
  /// past the window and recomputing must let the pane fall out of
  /// `.loading`. This is the "Claude Code finished thinking and the
  /// user is back at the prompt" path — no OSC 9;4 leave, no
  /// paneIdle, just the title burst trailing off.
  @Test
  func titleRateDecayingReleasesLoading() async {
    let clock = LockIsolated<Date>(Date(timeIntervalSince1970: 1_000))
    let running = LockIsolated<Set<PaneID>>([])
    let registry = AgentRegistry(
      runningPanes: { running.value },
      focusedPane: { nil },
      now: { clock.value }
    )
    let paneID = PaneID()
    registry.onAgentBound(paneID, kind: .claudeCode, sessionID: nil)

    registry.onTerminalEvent(.paneInfoChanged(paneID, .title("✶ Thinking")))
    clock.setValue(Date(timeIntervalSince1970: 1_000.5))
    registry.onTerminalEvent(.paneInfoChanged(paneID, .title("✶ Thinking (10k)")))
    clock.setValue(Date(timeIntervalSince1970: 1_001.0))
    registry.onTerminalEvent(.paneInfoChanged(paneID, .title("✶ Thinking (20k)")))
    #expect(registry.entries[paneID]?.state == .loading)

    // Jump past the rolling window. Without firing a new event,
    // re-derivation happens via the decay task scheduled after the
    // last title delta. Sleep just past the window + decay
    // jitter to let the @MainActor decay task fire.
    clock.setValue(Date(timeIntervalSince1970: 1_010.0))
    try? await Task.sleep(for: .seconds(2.5))
    #expect(registry.entries[paneID]?.state == .finished)
  }

  /// (5) From `.finished`, `onPaneKeyboardActivity` → `.idle`.
  @Test
  func keyboardActivityClearsFinishedBackToIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.running.setValue([f.paneID])
    f.registry.onRunningPanesChanged([f.paneID])
    f.running.setValue([])
    f.registry.onRunningPanesChanged([])
    #expect(f.registry.entries[f.paneID]?.state == .finished)

    f.registry.onPaneKeyboardActivity(f.paneID)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  /// (6) From `.finished`, `onPaneFocused` → `.idle`.
  @Test
  func focusClearsFinishedBackToIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.running.setValue([f.paneID])
    f.registry.onRunningPanesChanged([f.paneID])
    f.running.setValue([])
    f.registry.onRunningPanesChanged([])
    #expect(f.registry.entries[f.paneID]?.state == .finished)

    f.registry.onPaneFocused(f.paneID)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  /// (7) From `.loading`, `paneIdle` while still in the running set
  /// flags `pendingFinished`. The pane is still running per the live
  /// closure, so derive still returns `.loading` (loading beats
  /// pendingFinished) — what we assert is that the *subsequent* exit
  /// from the running set lands on `.finished`. Tests 7a-7b cover both
  /// readings of the spec: the inline state, and the resulting
  /// transition after the runtime catches up.
  @Test
  func paneIdleWhileLoadingArmsFinished() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.running.setValue([f.paneID])
    f.registry.onRunningPanesChanged([f.paneID])
    #expect(f.registry.entries[f.paneID]?.state == .loading)

    // paneIdle while loading arms pendingFinished. Per the priority
    // rule (loading beats pendingFinished), the surfaced state is
    // still .loading at this instant.
    f.registry.onTerminalEvent(.paneIdle(f.paneID, duration: 30))
    #expect(f.registry.entries[f.paneID]?.state == .loading)

    // Once the running-pane set catches up and the pane leaves,
    // pendingFinished is *not* re-armed (already true), prevPhase
    // flips to .idle, and the state surfaces as .finished — proving
    // the paneIdle arm was load-bearing.
    f.running.setValue([])
    f.registry.onRunningPanesChanged([])
    #expect(f.registry.entries[f.paneID]?.state == .finished)
  }

  /// (8) `paneExited` is teardown — entry is dropped from `entries`.
  @Test
  func paneExitedDropsEntry() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.running.setValue([f.paneID])
    f.registry.onRunningPanesChanged([f.paneID])
    #expect(f.registry.entries[f.paneID] != nil)

    f.registry.onTerminalEvent(.paneExited(f.paneID, code: 0, signal: nil))
    #expect(f.registry.entries[f.paneID] == nil)
  }

  /// (9) From `.idle`, an OSC 9 desktop notification whose
  /// title/body classify as `.waitingForInput` flips the entry to
  /// `.waitingForInput`. The classifier under test is
  /// `DetectionTranslator.classify` — `"Approve this action"` hits
  /// the `"approv"` lexical cue.
  @Test
  func waitingForInputDesktopNotificationFlipsState() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    #expect(f.registry.entries[f.paneID]?.state == .idle)

    f.registry.onTerminalEvent(
      .paneInfoChanged(
        f.paneID,
        .desktopNotification(title: "Approve this action", body: "Run command?")
      )
    )
    #expect(f.registry.entries[f.paneID]?.state == .waitingForInput)
  }

  /// (10) From `.waitingForInput`, `onPaneKeyboardActivity` clears
  /// the sticky flag and the state falls back to `.idle` (no
  /// running, no pending).
  @Test
  func keyboardActivityClearsWaitingForInput() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.registry.onTerminalEvent(
      .paneInfoChanged(
        f.paneID,
        .desktopNotification(title: "Approve this action", body: "?")
      )
    )
    #expect(f.registry.entries[f.paneID]?.state == .waitingForInput)

    f.registry.onPaneKeyboardActivity(f.paneID)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  /// (11) Priority: `waitingForInput` outranks `loading`. With both
  /// signals active the derived state is `.waitingForInput`.
  @Test
  func waitingForInputBeatsLoading() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.running.setValue([f.paneID])
    f.registry.onRunningPanesChanged([f.paneID])
    #expect(f.registry.entries[f.paneID]?.state == .loading)

    f.registry.onTerminalEvent(
      .paneInfoChanged(
        f.paneID,
        .desktopNotification(title: "Approve this action", body: "?")
      )
    )
    #expect(f.registry.entries[f.paneID]?.state == .waitingForInput)
  }

  /// (12) `onAgentUnbound` drops the entry; subsequent terminal
  /// events for the same pane are silent no-ops (no entry resurrects
  /// because no scratch survives either).
  @Test
  func unbindDropsEntryAndSilencesFutureEvents() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    #expect(f.registry.entries[f.paneID] != nil)

    f.registry.onAgentUnbound(f.paneID)
    #expect(f.registry.entries[f.paneID] == nil)

    // Subsequent events do not re-create an entry — agent is gone
    // until something rebinds.
    f.registry.onTerminalEvent(.paneOutput(f.paneID, Data()))
    f.registry.onTerminalEvent(
      .paneInfoChanged(
        f.paneID,
        .desktopNotification(title: "Approve this action", body: "?")
      )
    )
    f.registry.onPaneKeyboardActivity(f.paneID)
    #expect(f.registry.entries[f.paneID] == nil)
  }

  // MARK: - Extra coverage

  /// Bell delta is treated as a synthetic `waitingForInput` cue,
  /// mirroring `DetectionTranslator.translate`'s bellRang branch.
  @Test
  func bellRangFlipsToWaitingForInput() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .bellRang))
    #expect(f.registry.entries[f.paneID]?.state == .waitingForInput)
  }

  /// `lastTransitionAt` updates on every state change and stays put
  /// across no-op recomputes. Driven by the injected `now` closure.
  @Test
  func lastTransitionAtTracksStateChanges() {
    let clock = LockIsolated<Date>(Date(timeIntervalSince1970: 1_000))
    let running = LockIsolated<Set<PaneID>>([])
    let registry = AgentRegistry(
      runningPanes: { running.value },
      focusedPane: { nil },
      now: { clock.value }
    )
    let paneID = PaneID()

    registry.onAgentBound(paneID, kind: .claudeCode, sessionID: nil)
    let t0 = registry.entries[paneID]?.lastTransitionAt
    #expect(t0 == Date(timeIntervalSince1970: 1_000))

    // Advance time and trigger a real transition.
    clock.setValue(Date(timeIntervalSince1970: 2_000))
    running.setValue([paneID])
    registry.onRunningPanesChanged([paneID])
    #expect(registry.entries[paneID]?.state == .loading)
    #expect(registry.entries[paneID]?.lastTransitionAt == Date(timeIntervalSince1970: 2_000))

    // Advance time but re-fire the *same* running-set: state stays
    // .loading, lastTransitionAt must not advance.
    clock.setValue(Date(timeIntervalSince1970: 3_000))
    registry.onRunningPanesChanged([paneID])
    #expect(registry.entries[paneID]?.lastTransitionAt == Date(timeIntervalSince1970: 2_000))
  }

  // MARK: - Fixture

  /// Per-test harness. Holds the test-controlled running-panes set
  /// and focused-pane reference in `LockIsolated` so the registry's
  /// closures can read them through normal `@MainActor` calls.
  @MainActor
  final class Fixture {
    let paneID = PaneID()
    let running = LockIsolated<Set<PaneID>>([])
    let focused = LockIsolated<PaneID?>(nil)
    let nowBox = LockIsolated<Date>(Date(timeIntervalSince1970: 0))
    let registry: AgentRegistry

    init() {
      let running = self.running
      let focused = self.focused
      let nowBox = self.nowBox
      self.registry = AgentRegistry(
        runningPanes: { running.value },
        focusedPane: { focused.value },
        now: { nowBox.value }
      )
    }
  }
}
