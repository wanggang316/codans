import Foundation

nonisolated struct OpenCodeObservationParser: AgentObservationParser {
  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    return AgentObservation(activity: Self.detectOpenCode(screen))
  }

  private static func detectOpenCode(_ content: String) -> AgentObservation.Activity {
    if content.contains("△ Permission required")
      || hasOpenCodeQuestionPrompt(content)
    {
      return .blocked
    }
    if AgentObservationText.hasInterruptPattern(content.lowercased()) {
      return .working
    }
    return .idle
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
