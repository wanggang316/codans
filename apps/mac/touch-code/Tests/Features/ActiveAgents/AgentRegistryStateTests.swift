import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

@MainActor
struct AgentRegistryStateTests {
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
  func workingViewportAfterInputDrivesLoading() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .loading)
  }

  @Test
  func activeToIdleInBackgroundDrivesFinished() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .loading)

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
    #expect(f.registry.entries[f.paneID]?.state == .loading)

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
  func titleChangesDoNotDriveLoadingAfterInput() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)

    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .title("Thinking")))
    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .tabTitle("Thinking..")))

    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func waitingForInputDesktopNotificationFlipsState() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onTerminalEvent(
      .paneInfoChanged(
        f.paneID,
        .desktopNotification(title: "Approve this action", body: "Run command?")
      )
    )
    #expect(f.registry.entries[f.paneID]?.state == .waitingForInput)
  }

  @Test
  func blockedViewportFlipsState() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.viewport("Allow command?\n[y/n]")
    #expect(f.registry.entries[f.paneID]?.state == .waitingForInput)
  }

  @Test
  func keyboardActivityClearsWaitingForInput() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.viewport("Allow command?\n[y/n]")
    #expect(f.registry.entries[f.paneID]?.state == .waitingForInput)

    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("codex> ")
    #expect(f.registry.entries[f.paneID]?.state == .idle)
  }

  @Test
  func waitingForInputBeatsLoading() {
    let f = Fixture()
    f.registry.onAgentBound(f.paneID, kind: .codex, sessionID: nil)
    f.registry.onPaneKeyboardActivity(f.paneID)
    f.viewport("• Working (10s)")
    #expect(f.registry.entries[f.paneID]?.state == .loading)

    f.registry.onTerminalEvent(.paneInfoChanged(f.paneID, .bellRang))
    #expect(f.registry.entries[f.paneID]?.state == .waitingForInput)
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
    let registry = AgentRegistry(
      focusedPane: { nil },
      now: { clock.value }
    )

    registry.onAgentBound(paneID, kind: .codex, sessionID: nil)
    #expect(registry.entries[paneID]?.lastTransitionAt == Date(timeIntervalSince1970: 1_000))

    clock.setValue(Date(timeIntervalSince1970: 2_000))
    registry.onPaneKeyboardActivity(paneID)
    registry.onTerminalEvent(.paneViewportChanged(paneID, text: "• Working (10s)"))
    #expect(registry.entries[paneID]?.state == .loading)
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
    let registry: AgentRegistry

    init() {
      let focused = self.focused
      let nowBox = self.nowBox
      self.registry = AgentRegistry(
        focusedPane: { focused.value },
        now: { nowBox.value }
      )
    }

    func viewport(_ text: String) {
      registry.onTerminalEvent(.paneViewportChanged(paneID, text: text))
    }
  }
}
