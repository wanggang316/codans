import Foundation

nonisolated struct OpenCodeObservationParser: AgentTerminalParser {
  func parse(_ text: String) -> TerminalParseResult {
    let screen = AgentObservationText.interactionLines(text, promptPrefixes: ["opencode>"]).joined(separator: "\n")
    return AgentObservationText.result(
      activity: Self.detectOpenCode(screen), text: screen, promptPrefixes: ["opencode>"])
  }

  private static func detectOpenCode(_ content: String) -> AgentObservedActivity {
    if content.contains("△ Permission required")
      || hasOpenCodeQuestionPrompt(content)
    {
      return .blocked
    }
    if AgentObservationText.hasInterruptPattern(content.lowercased()) {
      return .working
    }
    return .unknown
  }

  private static func hasOpenCodeQuestionPrompt(_ content: String) -> Bool {
    let lower = content.lowercased()
    let hasEnterAction =
      lower.contains("enter confirm")
      || lower.contains("enter submit")
      || lower.contains("enter toggle")
    let hasQuestionNavigation =
      content.contains("↑↓ select")
      || content.contains("⇆ tab")

    return lower.contains("esc dismiss") && hasEnterAction && hasQuestionNavigation
  }

}
