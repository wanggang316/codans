import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

@MainActor
struct AgentStateStoreTests {
  @Test
  func boundOnlyYieldsIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func workingViewportWithoutInputStaysIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func workingViewportAfterInputDrivesWorking() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .working)
  }

  @Test
  func existingBoundAgentCanWorkBeforeCurrentSessionInput() {
    let f = Fixture()
    f.registry.onAgentBound(
      f.paneID,
      kind: .codex,
      sessionID: nil,
      assumeUserInputSeen: true
    )
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .working)
  }

  @Test
  func bindAcceptsClassifierWhenViewportAlreadyShowsActive() {
    // Viewport arrives before the binding forms — e.g. a fresh pane spawned
    // with an immediately-running agent (`codex --resume` via a script).
    // The bound classifier should accept the viewport cue without waiting
    // for the user to type into this pane first.
    let f = Fixture()
    f.viewport("• Working (10s)")
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    #expect(f.registry.entries[f.paneID]?.state == .working)
  }

  @Test
  func seededWorkingSurvivesLaunchRebind() {
    // An agent persisted as `.working` at quit must keep
    // that badge after launch. The binder re-identifies the restored agent
    // and fires `onAgentBound`; it must not collapse the seeded state to
    // `.idle` before any live viewport classification arrives.
    let f = Fixture()
    f.registry.seedRestored([(paneID: f.paneID, kind: .codex, state: .working)])
    #expect(f.registry.entries[f.paneID]?.state == .working)

    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: "s1")
    #expect(f.registry.entries[f.paneID]?.state == .working)
  }

  @Test
  func seededBlockedSurvivesLaunchRebind() {
    let f = Fixture()
    f.registry.seedRestored([(paneID: f.paneID, kind: .codex, state: .blocked)])
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: "s1")
    #expect(f.registry.entries[f.paneID]?.state == .blocked)
  }

  @Test
  func seededStateYieldsToLiveViewport() {
    // The seed is only a bridge until live signals return. Once a real
    // viewport classification lands it governs — here the restored agent
    // has finished, so its idle prompt drives the badge back to idle.
    let f = Fixture()
    f.registry.seedRestored([(paneID: f.paneID, kind: .codex, state: .working)])
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: "s1")

    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func seededWorkingConfirmedByLiveViewport() {
    // A genuinely still-working restored agent keeps `.working` once its
    // live working cue re-renders.
    let f = Fixture()
    f.registry.seedRestored([(paneID: f.paneID, kind: .codex, state: .working)])
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: "s1")

    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .working)
  }

  @Test
  func activeToIdleInBackgroundDrivesFinished() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .working)

    // The working→idle hold now applies to every kind, so the completion
    // only settles once the hold window has lapsed.
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .finished)
  }

  @Test
  func nonClaudeWorkingStateIsHeldThenSettles() {
    // Generalization regression: the working→idle debounce is no longer
    // Claude-only. A codex pane whose completion prompt renders within the
    // hold window keeps `working`, then settles once the window lapses —
    // eliminating the Working↔Done flicker on a single dropped frame.
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .working)

    // Idle prompt arrives immediately (t == lastWorkingAt): held as working.
    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .working)

    // Past the hold, a follow-up idle derivation settles it to finished.
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .finished)
  }

  @Test
  func claudePaneIdleFlushesHeldWorkingToFinished() {
    // Regression (fix/agents-view-done-wrong): the `agentWorkingHold`
    // debounces the finishing `working`→`idle` transition. The trailing edge
    // only flips on a follow-up derivation, but once the rendered region
    // settles no further `paneViewportChanged` fires — so the held `working`
    // was getting pinned forever. The engine's quiet `.paneIdle` nudge now
    // supplies that post-hold derivation; here it must flip a backgrounded,
    // finished Claude agent to `.finished`.
    let clock = LockIsolated<Date>(Date(timeIntervalSince1970: 1_000))
    let paneID = PaneID()
    let registry = AgentStateStore(focusedPane: { nil }, now: { clock.value })

    registry.onAgentBound(paneID, kind: .claudeCode, sessionID: nil)
    registry.onPaneKeyboardActivity(paneID)
    registry.onTerminalEvent(.paneViewportChanged(paneID, text: "✢ Editing…"))
    #expect(registry.entries[paneID]?.state == .working)

    // Agent finishes: idle prompt renders, but the hold pins working.
    clock.setValue(Date(timeIntervalSince1970: 1_000.3))
    registry.onTerminalEvent(.paneViewportChanged(paneID, text: "❯ "))
    #expect(registry.entries[paneID]?.state == .working)

    // Screen settled; the quiet nudge arrives past the hold window → finished.
    clock.setValue(Date(timeIntervalSince1970: 1_002))
    registry.onTerminalEvent(.paneIdle(paneID, duration: 1.7))
    #expect(registry.entries[paneID]?.state == .finished)
  }

  @Test
  func focusedCompletionStaysIdle() {
    let f = Fixture()
    f.focused.setValue(f.paneID)
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .working)

    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func keyboardActivityClearsFinishedBackToIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .finished)

    f.registry.onPaneKeyboardActivity(f.paneID)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func focusClearsFinishedBackToIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .finished)

    f.registry.onPaneFocused(f.paneID)
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func paneOutputDoesNotChangeFinishedState() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .finished)

    f.registry.onTerminalEvent(.paneOutput(f.paneID, Data()))
    #expect(f.registry.entries[f.paneID]?.state == .finished)
  }

  @Test
  func titleChangesDoNotDriveWorkingAfterInput() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)

    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .title("Thinking")))
    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .tabTitle("Thinking..")))

    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func desktopNotificationDoesNotFlipLiveState() {
    // A desktop notification is an inbox-worthy event, not a live activity
    // signal. With no rendered activity yet, the live state stays idle —
    // the notifications inbox records it independently.
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onTerminalEvent(
      .paneInfoChanged(
        f.paneID,
        .desktopNotification(title: "Approve this action", body: "Run command?")
      )
    )
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func blockedViewportFlipsState() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.viewport("Allow command?\n[y/n]")
    #expect(f.registry.entries[f.paneID]?.state == .blocked)
  }

  @Test
  func keyboardActivityClearsBlocked() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.viewport("Allow command?\n[y/n]")
    #expect(f.registry.entries[f.paneID]?.state == .blocked)

    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func bellDoesNotOverrideWorking() {
    // The terminal bell rings for many non-input reasons (completion beeps,
    // error tones, finished commands). It must not pin a working agent into
    // the blocked state — only the rendered region decides live activity.
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .working)

    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .bellRang))
    #expect(f.registry.entries[f.paneID]?.state == .working)
  }

  @Test
  func bellDoesNotFlipIdleToBlocked() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .idle)

    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .bellRang))
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func paneExitedDropsEntry() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    #expect(f.registry.entries[f.paneID] != nil)

    f.registry.onTerminalEvent(.paneExited(f.paneID, code: 0, signal: nil))
    #expect(f.registry.entries[f.paneID] == nil)
  }

  @Test
  func unbindDropsEntryAndSilencesFutureEvents() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    #expect(f.registry.entries[f.paneID] != nil)

    f.registry.onAgentUnbound(f.paneID)
    f.viewport("• Working (10s)")
    f.registry.onTerminalEvent(
      .paneInfoChanged(
        f.paneID,
        .desktopNotification(title: "Approve this action", body: "?")
      )
    )
    f.registry.onPaneKeyboardActivity(f.paneID)
    #expect(f.registry.entries[f.paneID] == nil)
  }

  @Test
  func lastTransitionAtTracksStateChanges() {
    let clock = LockIsolated<Date>(Date(timeIntervalSince1970: 1_000))
    let paneID = PaneID()
    let registry = AgentStateStore(
      focusedPane: { nil },
      now: { clock.value }
    )

    registry.onAgentBound(paneID, kind: .codex, sessionID: nil)
    #expect(registry.entries[paneID]?.lastTransitionAt == Date(timeIntervalSince1970: 1_000))

    clock.setValue(Date(timeIntervalSince1970: 2_000))
    registry.onPaneKeyboardActivity(paneID)
    registry.onTerminalEvent(.paneViewportChanged(paneID, text: "• Working (10s)"))
    #expect(registry.entries[paneID]?.state == .working)
    #expect(registry.entries[paneID]?.lastTransitionAt == Date(timeIntervalSince1970: 2_000))

    clock.setValue(Date(timeIntervalSince1970: 3_000))
    registry.onTerminalEvent(.paneViewportChanged(paneID, text: "• Working (10s)"))
    #expect(registry.entries[paneID]?.lastTransitionAt == Date(timeIntervalSince1970: 2_000))
  }

  @Test
  func reconcileDropsEntryAbsentFromCatalog() {
    // The production ghost: a bound pane that left the hierarchy without a
    // teardown event reaching the store. Its entry can never resolve to a
    // project/worktree (renders an em-dash row), so the membership reconcile
    // must drop it.
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    #expect(f.registry.entries[f.paneID] != nil)

    f.registry.reconcileMembership(livePaneIDs: [])
    #expect(f.registry.entries[f.paneID] == nil)
  }

  @Test
  func reconcileKeepsEntryStillInCatalog() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)

    f.registry.reconcileMembership(livePaneIDs: [f.paneID])
    #expect(f.registry.entries[f.paneID] != nil)
  }

  @Test
  func reconcileDropsOnlyAbsentEntries() {
    // A reconcile triggered by one pane's removal must leave the bindings of
    // panes that are still in the catalog untouched.
    let f = Fixture()
    let live = PaneID()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onAgentBound(live, kind: .codex, sessionID: nil)

    f.registry.reconcileMembership(livePaneIDs: [live])
    #expect(f.registry.entries[f.paneID] == nil)
    #expect(f.registry.entries[live] != nil)
  }

  @Test
  func reconcileDropsSeededGhostAndItsScratch() {
    // A launch seed for a pane the catalog no longer hosts (daemon socket
    // briefly alive, hierarchy already pruned) — the exact case behind the
    // two em-dash rows in production. The reconcile drops the seeded entry;
    // a late viewport for the dropped pane must not resurrect a row, proving
    // the scratch was dropped alongside the entry.
    let f = Fixture()
    f.registry.seedRestored([(paneID: f.paneID, kind: .codex, state: .working)])
    #expect(f.registry.entries[f.paneID]?.state == .working)

    f.registry.reconcileMembership(livePaneIDs: [])
    #expect(f.registry.entries[f.paneID] == nil)

    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID] == nil)
  }

  @Test
  func titleTracksLatestPaneInfoAndClearsOnTeardown() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .claudeCode, sessionID: nil)
    #expect(f.registry.title(for: f.paneID) == nil)

    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .title("✳ Running tests…")))
    #expect(f.registry.title(for: f.paneID) == "✳ Running tests…")

    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .title("✳ Committing…")))
    #expect(f.registry.title(for: f.paneID) == "✳ Committing…")

    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .title(nil)))
    #expect(f.registry.title(for: f.paneID) == nil)

    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .title("post-teardown?")))
    f.registry.onTerminalEvent(.paneExited(f.paneID, code: 0, signal: nil))
    #expect(f.registry.title(for: f.paneID) == nil)
  }

  @Test
  func titleObservedBeforeBindSurvivesTheBind() {
    let f = Fixture()
    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .title("early title")))
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    #expect(f.registry.title(for: f.paneID) == "early title")
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @MainActor
  final class Fixture {
    let paneID = PaneID()
    let focused = LockIsolated<PaneID?>(nil)
    let nowBox = LockIsolated<Date>(Date(timeIntervalSince1970: 0))
    let registry: AgentStateStore

    init() {
      let focused = self.focused
      let nowBox = self.nowBox
      self.registry = AgentStateStore(
        focusedPane: { focused.value },
        now: { nowBox.value }
      )
    }

    func viewport(_ text: String) {
      registry.onTerminalEvent(.paneViewportChanged(paneID, text: text))
    }

    /// Advance the injected clock past `agentWorkingHold` so a subsequent
    /// idle classification is no longer debounced as `working`.
    func advancePastWorkingHold() {
      nowBox.setValue(
        nowBox.value.addingTimeInterval(PaneAttentionInterpreter.agentWorkingHold + 0.5)
      )
    }
  }
}
