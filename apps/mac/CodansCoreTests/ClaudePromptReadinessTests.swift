import Testing

@testable import CodansCore

struct ClaudePromptReadinessTests {
  @Test(arguments: ["", "Claude Code v2.1\nLoading…", "❯", "────────\nStarting Claude Code…\n────────"])
  func startupDoesNotProveReadiness(_ screen: String) {
    #expect(!PaneAttentionInterpreter.hasEmptyClaudePrompt(viewportText: screen))
  }

  @Test
  func borderedEmptyComposerIsReady() {
    #expect(
      PaneAttentionInterpreter.hasEmptyClaudePrompt(
        viewportText: "Claude Code\n────────\n❯ \n────────\n? for shortcuts"))
  }

  @Test(arguments: ["❯ Existing draft", "❯\nsecond draft line"])
  func existingDraftIsNotReady(_ composer: String) {
    #expect(!PaneAttentionInterpreter.hasEmptyClaudePrompt(viewportText: "────────\n\(composer)\n────────"))
  }

  @Test(arguments: ["Do you want to proceed?", "Working… esc to interrupt", "⌕ Search…"])
  func interactiveOrWorkingScreenIsNotReady(_ heading: String) {
    #expect(!PaneAttentionInterpreter.hasEmptyClaudePrompt(viewportText: "\(heading)\n────────\n❯\n────────"))
  }
}
