import Testing

@testable import Codans

@MainActor
struct QuitConfirmationDialogTests {
  @Test
  func messageTextCountsBusyPanes() {
    #expect(
      QuitConfirmationDialog.messageText(busyPaneCount: 0)
        == "No panes are busy. How should open sessions be handled?")
    #expect(
      QuitConfirmationDialog.messageText(busyPaneCount: 1)
        == "1 pane is busy. How should it be handled?")
    #expect(
      QuitConfirmationDialog.messageText(busyPaneCount: 3)
        == "3 panes are busy. How should they be handled?")
  }

  /// An agent waiting at its prompt must not count as busy — that is the
  /// case that used to prompt on every quit.
  @Test
  func onlyAnOpenAgentTurnIsMidTask() {
    typealias State = AgentStateStore.AgentRuntimeState
    #expect(State.working.isMidTask)
    #expect(State.blocked.isMidTask)
    #expect(!State.idle.isMidTask)
    #expect(!State.finished.isMidTask)
  }
}
