import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

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
  func activeToIdleInBackgroundDrivesFinished() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .working)

    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .finished)
  }

  @Test
  func focusedCompletionStaysIdle() {
    let f = Fixture()
    f.focused.setValue(f.paneID)
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .working)

    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func keyboardActivityClearsFinishedBackToIdle() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
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
  }
}
