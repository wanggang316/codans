import Foundation

nonisolated struct GeminiObservationParser: AgentObservationParser {
  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    return AgentObservation(activity: Self.detectGemini(screen))
  }

  private static func detectGemini(_ content: String) -> AgentObservation.Activity {
    let lower = content.lowercased()
    if lower.contains("waiting for user confirmation")
      || content.contains("│ Apply this change")
      || content.contains("│ Allow execution")
      || content.contains("│ Do you want to proceed")
      || AgentObservationText.hasConfirmationPrompt(lower)
    {
      return .blocked
    }
    if lower.contains("esc to cancel") {
      return .working
    }
    return .idle
  }

}
