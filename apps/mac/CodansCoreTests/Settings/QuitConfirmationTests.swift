import Testing

@testable import CodansCore

struct QuitConfirmationTests {
  @Test
  func autoPromptsOnlyWhenAPaneIsBusy() {
    #expect(QuitConfirmation.auto.shouldPrompt(busyPaneCount: 0) == false)
    #expect(QuitConfirmation.auto.shouldPrompt(busyPaneCount: 1) == true)
    #expect(QuitConfirmation.auto.shouldPrompt(busyPaneCount: 3) == true)
  }

  @Test
  func alwaysPromptsEvenWithNothingBusy() {
    #expect(QuitConfirmation.always.shouldPrompt(busyPaneCount: 0) == true)
    #expect(QuitConfirmation.always.shouldPrompt(busyPaneCount: 2) == true)
  }

  @Test
  func neverPromptsEvenWithBusyPanes() {
    #expect(QuitConfirmation.never.shouldPrompt(busyPaneCount: 0) == false)
    #expect(QuitConfirmation.never.shouldPrompt(busyPaneCount: 2) == false)
  }
}
