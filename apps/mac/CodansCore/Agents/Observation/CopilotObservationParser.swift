import Foundation

nonisolated struct CopilotObservationParser: AgentObservationParser {
  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    return AgentObservation(activity: Self.detectCopilot(screen))
  }

  private static func detectCopilot(_ content: String) -> AgentObservation.Activity {
    let lower = content.lowercased()
    if lower.contains("│ do you want")
      || (lower.contains("confirm with") && lower.contains("enter"))
    {
      return .blocked
    }
    if lower.contains("esc to cancel") {
      return .working
    }
    return .idle
  }

}
