import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

@MainActor
struct AgentStateStoreTests {
  @Test
  func piBorderLoaderTransitionsFromIdleThroughWorkingToDone() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .pi, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("── ⠋ Working ─────────\n\n─────────────────────")
    #expect(f.registry.entries[f.contentID]?.state == .working)
    f.viewport("─────────────────────\n\n─────────────────────")
    #expect(f.registry.entries[f.contentID]?.state == .working)
    f.advancePastWorkingHold()
    f.viewport("─────────────────────\n\n─────────────────────")
    #expect(f.registry.entries[f.contentID]?.state == .done)
  }

  @Test
  func boundOnlyYieldsIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func workingViewportWithoutInputStaysIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func workingViewportAfterInputDrivesWorking() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.contentID]?.state == .working)
  }

  @Test
  func existingBoundAgentCanWorkBeforeCurrentSessionInput() {
    let f = Fixture()
    f.registry.onAgentBound(
      f.contentID,
      kind: .codex,
      sessionID: nil,
      assumeUserInputSeen: true
    )
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.contentID]?.state == .working)
  }

  @Test
  func bindAcceptsClassifierWhenViewportAlreadyShowsActive() {
    // Viewport arrives before the binding forms — e.g. a fresh pane spawned
    // with an immediately-running agent (`codex --resume` via a script).
    // The bound classifier should accept the viewport cue without waiting
    // for the user to type into this pane first.
    let f = Fixture()
    f.viewport("• Working (10s)")
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    #expect(f.registry.entries[f.contentID]?.state == .working)
  }

  @Test
  func seededWorkingSurvivesLaunchRebind() {
    // An agent persisted as `.working` at quit must keep
    // that badge after launch. The binder re-identifies the restored agent
    // and fires `onAgentBound`; it must not collapse the seeded state to
    // `.idle` before any live viewport classification arrives.
    let f = Fixture()
    f.registry.seedRestored([(contentID: f.contentID, kind: .codex, state: .working)])
    #expect(f.registry.entries[f.contentID]?.state == .working)

    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: "s1")
    #expect(f.registry.entries[f.contentID]?.state == .working)
  }

  @Test
  func seededBlockedSurvivesLaunchRebind() {
    let f = Fixture()
    f.registry.seedRestored([(contentID: f.contentID, kind: .codex, state: .blocked)])
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: "s1")
    #expect(f.registry.entries[f.contentID]?.state == .blocked)
  }

  @Test
  func seededStateYieldsToLiveViewport() {
    // The seed is only a bridge until live signals return. Once a real
    // viewport classification lands it governs — here the restored agent
    // has finished, so its idle prompt drives the badge back to idle.
    let f = Fixture()
    f.registry.seedRestored([(contentID: f.contentID, kind: .codex, state: .working)])
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: "s1")

    f.viewport("codex> ")
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func seededWorkingConfirmedByLiveViewport() {
    // A genuinely still-working restored agent keeps `.working` once its
    // live working cue re-renders.
    let f = Fixture()
    f.registry.seedRestored([(contentID: f.contentID, kind: .codex, state: .working)])
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: "s1")

    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.contentID]?.state == .working)
  }

  @Test
  func activeToIdleInBackgroundDrivesDone() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.contentID]?.state == .working)

    // The working→idle hold now applies to every kind, so the completion
    // only settles once the hold window has lapsed.
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.contentID]?.state == .done)
  }

  @Test
  func nonClaudeWorkingStateIsHeldThenSettles() {
    // Generalization regression: the working→idle debounce is no longer
    // Claude-only. A codex pane whose completion prompt renders within the
    // hold window keeps `working`, then settles once the window lapses —
    // eliminating the Working↔Done flicker on a single dropped frame.
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.contentID]?.state == .working)

    // Idle prompt arrives immediately (t == lastWorkingAt): held as working.
    f.viewport("codex> ")
    #expect(f.registry.entries[f.contentID]?.state == .working)

    // Past the hold, a follow-up idle derivation settles it to done.
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.contentID]?.state == .done)
  }

  @Test
  func claudePaneIdleFlushesHeldWorkingToDone() {
    // Regression (fix/agents-view-done-wrong): the `agentWorkingHold`
    // debounces the finishing `working`→`idle` transition. The trailing edge
    // only flips on a follow-up derivation, but once the rendered region
    // settles no further `paneViewportChanged` fires — so the held `working`
    // was getting pinned forever. The engine's quiet `.paneIdle` nudge now
    // supplies that post-hold derivation; here it must flip a backgrounded,
    // finished Claude agent to `.done`.
    let clock = LockIsolated<Date>(Date(timeIntervalSince1970: 1_000))
    let contentID = ContentID()
    let registry = AgentStateStore(focusedPane: { nil }, now: { clock.value })

    registry.onAgentBound(contentID, kind: .claudeCode, sessionID: nil)
    registry.onPaneKeyboardActivity(contentID)
    registry.onTerminalEvent(.paneViewportChanged(contentID, text: "✢ Editing…"))
    #expect(registry.entries[contentID]?.state == .working)

    // Agent finishes: idle prompt renders, but the hold pins working.
    clock.setValue(Date(timeIntervalSince1970: 1_000.3))
    registry.onTerminalEvent(.paneViewportChanged(contentID, text: "❯ "))
    #expect(registry.entries[contentID]?.state == .working)

    // Screen settled; the quiet nudge arrives past the hold window → done.
    clock.setValue(Date(timeIntervalSince1970: 1_002))
    registry.onTerminalEvent(.paneIdle(contentID, duration: 1.7))
    #expect(registry.entries[contentID]?.state == .done)
  }

  @Test
  func focusedCompletionStaysIdle() {
    let f = Fixture()
    f.focused.setValue(f.contentID)
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.contentID]?.state == .working)

    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func keyboardActivityClearsDoneBackToIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("• Working (10s)")
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.contentID]?.state == .done)

    f.registry.onPaneKeyboardActivity(f.contentID)
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func focusClearsDoneBackToIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("• Working (10s)")
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.contentID]?.state == .done)

    f.registry.onPaneFocused(f.contentID)
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func paneOutputDoesNotChangeDoneState() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("• Working (10s)")
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(f.registry.entries[f.contentID]?.state == .done)

    f.registry.onTerminalEvent(.paneOutput(f.contentID, Data()))
    #expect(f.registry.entries[f.contentID]?.state == .done)
  }

  @Test
  func titleChangesDoNotDriveWorkingAfterInput() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)

    f.registry.onTerminalEvent(.paneInfoChanged(f.contentID, .title("Thinking")))
    f.registry.onTerminalEvent(.paneInfoChanged(f.contentID, .tabTitle("Thinking..")))

    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func desktopNotificationDoesNotFlipLiveState() {
    // A desktop notification is an inbox-worthy event, not a live activity
    // signal. With no rendered activity yet, the live state stays idle —
    // the notifications inbox records it independently.
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onTerminalEvent(
      .paneInfoChanged(
        f.contentID,
        .desktopNotification(title: "Approve this action", body: "Run command?")
      )
    )
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func blockedViewportFlipsState() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.viewport("Allow command?\n[y/n]")
    #expect(f.registry.entries[f.contentID]?.state == .blocked)
  }

  @Test
  func keyboardActivityClearsBlocked() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.viewport("Allow command?\n[y/n]")
    #expect(f.registry.entries[f.contentID]?.state == .blocked)

    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("codex> ")
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func bellDoesNotOverrideWorking() {
    // The terminal bell rings for many non-input reasons (completion beeps,
    // error tones, finished commands). It must not pin a working agent into
    // the blocked state — only the rendered region decides live activity.
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.contentID]?.state == .working)

    f.registry.onTerminalEvent(.paneInfoChanged(f.contentID, .bellRang))
    #expect(f.registry.entries[f.contentID]?.state == .working)
  }

  @Test
  func bellDoesNotFlipIdleToBlocked() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("codex> ")
    #expect(f.registry.entries[f.contentID]?.state == .idle)

    f.registry.onTerminalEvent(.paneInfoChanged(f.contentID, .bellRang))
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  @Test
  func paneExitedDropsEntry() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    #expect(f.registry.entries[f.contentID] != nil)

    f.registry.onTerminalEvent(.paneExited(f.contentID, code: 0, signal: nil))
    #expect(f.registry.entries[f.contentID] == nil)
  }

  @Test
  func unbindDropsEntryAndSilencesFutureEvents() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    #expect(f.registry.entries[f.contentID] != nil)

    f.registry.onAgentUnbound(f.contentID)
    f.viewport("• Working (10s)")
    f.registry.onTerminalEvent(
      .paneInfoChanged(
        f.contentID,
        .desktopNotification(title: "Approve this action", body: "?")
      )
    )
    f.registry.onPaneKeyboardActivity(f.contentID)
    #expect(f.registry.entries[f.contentID] == nil)
  }

  @Test
  func lastTransitionAtTracksStateChanges() {
    let clock = LockIsolated<Date>(Date(timeIntervalSince1970: 1_000))
    let contentID = ContentID()
    let registry = AgentStateStore(
      focusedPane: { nil },
      now: { clock.value }
    )

    registry.onAgentBound(contentID, kind: .codex, sessionID: nil)
    #expect(registry.entries[contentID]?.lastTransitionAt == Date(timeIntervalSince1970: 1_000))

    clock.setValue(Date(timeIntervalSince1970: 2_000))
    registry.onPaneKeyboardActivity(contentID)
    registry.onTerminalEvent(.paneViewportChanged(contentID, text: "• Working (10s)"))
    #expect(registry.entries[contentID]?.state == .working)
    #expect(registry.entries[contentID]?.lastTransitionAt == Date(timeIntervalSince1970: 2_000))

    clock.setValue(Date(timeIntervalSince1970: 3_000))
    registry.onTerminalEvent(.paneViewportChanged(contentID, text: "• Working (10s)"))
    #expect(registry.entries[contentID]?.lastTransitionAt == Date(timeIntervalSince1970: 2_000))
  }

  @Test
  func reconcileDropsEntryAbsentFromCatalog() {
    // The production ghost: a bound pane that left the hierarchy without a
    // teardown event reaching the store. Its entry can never resolve to a
    // project/worktree (renders an em-dash row), so the membership reconcile
    // must drop it.
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    #expect(f.registry.entries[f.contentID] != nil)

    f.registry.reconcileMembership(liveContentIDs: [])
    #expect(f.registry.entries[f.contentID] == nil)
  }

  @Test
  func reconcileKeepsEntryStillInCatalog() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)

    f.registry.reconcileMembership(liveContentIDs: [f.contentID])
    #expect(f.registry.entries[f.contentID] != nil)
  }

  @Test
  func reconcileDropsOnlyAbsentEntries() {
    // A reconcile triggered by one pane's removal must leave the bindings of
    // panes that are still in the catalog untouched.
    let f = Fixture()
    let live = ContentID()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onAgentBound(live, kind: .codex, sessionID: nil)

    f.registry.reconcileMembership(liveContentIDs: [live])
    #expect(f.registry.entries[f.contentID] == nil)
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
    f.registry.seedRestored([(contentID: f.contentID, kind: .codex, state: .working)])
    #expect(f.registry.entries[f.contentID]?.state == .working)

    f.registry.reconcileMembership(liveContentIDs: [])
    #expect(f.registry.entries[f.contentID] == nil)

    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.contentID] == nil)
  }

  @Test
  func titleTracksLatestPaneInfoAndClearsOnTeardown() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .claudeCode, sessionID: nil)
    #expect(f.registry.title(for: f.contentID) == nil)

    f.registry.onTerminalEvent(.paneInfoChanged(f.contentID, .title("✳ Running tests…")))
    #expect(f.registry.title(for: f.contentID) == "✳ Running tests…")

    f.registry.onTerminalEvent(.paneInfoChanged(f.contentID, .title("✳ Committing…")))
    #expect(f.registry.title(for: f.contentID) == "✳ Committing…")

    f.registry.onTerminalEvent(.paneInfoChanged(f.contentID, .title(nil)))
    #expect(f.registry.title(for: f.contentID) == nil)

    f.registry.onTerminalEvent(.paneInfoChanged(f.contentID, .title("post-teardown?")))
    f.registry.onTerminalEvent(.paneExited(f.contentID, code: 0, signal: nil))
    #expect(f.registry.title(for: f.contentID) == nil)
  }

  @Test
  func titleObservedBeforeBindSurvivesTheBind() {
    let f = Fixture()
    f.registry.onTerminalEvent(.paneInfoChanged(f.contentID, .title("early title")))
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    #expect(f.registry.title(for: f.contentID) == "early title")
    #expect(f.registry.entries[f.contentID]?.state == .idle)
  }

  // MARK: - Attention observation (notification suppression)

  @Test
  func focusAfterBlockedCountsAsObserved() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.viewport("Allow command?\n[y/n]")
    #expect(!f.registry.hasObservedAttention(f.contentID))

    f.inView.setValue(true)
    f.registry.onPaneFocused(f.contentID)
    f.inView.setValue(false)
    #expect(f.registry.hasObservedAttention(f.contentID))

    // The prompt re-renders after the optimistic clear. Still the same stop.
    f.registry.onTerminalEvent(.paneIdle(f.contentID, duration: 1))
    f.viewport("Allow command?\n[y/n]")
    #expect(f.registry.hasObservedAttention(f.contentID))
  }

  @Test
  func finishWhileInViewCountsAsObserved() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.inView.setValue(true)
    f.finishTurn()
    f.inView.setValue(false)
    #expect(f.registry.hasObservedAttention(f.contentID))
  }

  @Test
  func finishInBackgroundIsNotObservedUntilFocused() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.finishTurn()
    #expect(f.registry.entries[f.contentID]?.state == .done)
    #expect(!f.registry.hasObservedAttention(f.contentID))

    f.inView.setValue(true)
    f.registry.markObserved(f.contentID)
    #expect(f.registry.hasObservedAttention(f.contentID))
  }

  @Test
  func focusWhileThePaneIsNotInViewIsNotObserved() {
    // A CLI `pane focus` selects the pane while another app is in front.
    // The badge clears, but the user has not seen the prompt.
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.viewport("Allow command?\n[y/n]")

    f.registry.onPaneFocused(f.contentID)
    f.registry.markObserved(f.contentID)
    #expect(f.registry.entries[f.contentID]?.state != .blocked)
    #expect(!f.registry.hasObservedAttention(f.contentID))
  }

  @Test
  func focusBeforeTheStopDoesNotCount() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("• Working (10s)")
    f.registry.onPaneFocused(f.contentID)
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(!f.registry.hasObservedAttention(f.contentID))
  }

  @Test
  func newTurnResetsObservation() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.inView.setValue(true)
    f.finishTurn()
    #expect(f.registry.hasObservedAttention(f.contentID))

    f.inView.setValue(false)
    f.registry.onPaneKeyboardActivity(f.contentID)
    f.viewport("• Working (10s)")
    #expect(!f.registry.hasObservedAttention(f.contentID))
    f.advancePastWorkingHold()
    f.viewport("codex> ")
    #expect(!f.registry.hasObservedAttention(f.contentID))
  }

  @Test
  func resolvedPromptEndsTheStop() {
    // The user looked at a prompt; it was then answered through the CLI (no
    // keystroke, so no `working`). The next prompt is a new stop.
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.viewport("Allow command?\n[y/n]")
    f.inView.setValue(true)
    f.registry.markObserved(f.contentID)
    f.inView.setValue(false)
    #expect(f.registry.hasObservedAttention(f.contentID))

    f.viewport("codex> ")
    f.viewport("Allow command?\n[y/n]")
    #expect(!f.registry.hasObservedAttention(f.contentID))
  }

  @Test
  func promptAfterClearedAndResolvedPromptIsANewStop() {
    let f = Fixture()
    f.registry.onAgentBound(f.contentID, kind: .codex, sessionID: nil)
    f.viewport("Allow command?\n[y/n]")
    f.inView.setValue(true)
    f.registry.onPaneFocused(f.contentID)
    f.inView.setValue(false)
    // Idle ticks before the next snapshot keep the same stop.
    f.registry.onTerminalEvent(.paneIdle(f.contentID, duration: 1))
    f.viewport("codex> ")
    #expect(f.registry.hasObservedAttention(f.contentID))

    f.viewport("Allow command?\n[y/n]")
    #expect(!f.registry.hasObservedAttention(f.contentID))
  }

  @MainActor
  final class Fixture {
    let contentID = ContentID()
    let focused = LockIsolated<ContentID?>(nil)
    let inView = LockIsolated(false)
    let nowBox = LockIsolated<Date>(Date(timeIntervalSince1970: 0))
    let registry: AgentStateStore

    init() {
      let focused = self.focused
      let nowBox = self.nowBox
      let inView = self.inView
      self.registry = AgentStateStore(
        focusedPane: { focused.value },
        isPaneInView: { _ in inView.value },
        now: { nowBox.value }
      )
    }

    /// One user turn that the agent finishes: input, working, then idle.
    func finishTurn() {
      registry.onPaneKeyboardActivity(contentID)
      viewport("• Working (10s)")
      advancePastWorkingHold()
      viewport("codex> ")
    }

    func viewport(_ text: String) {
      registry.onTerminalEvent(.paneViewportChanged(contentID, text: text))
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
