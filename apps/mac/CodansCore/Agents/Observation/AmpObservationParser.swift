import Foundation

nonisolated struct AmpObservationParser: AgentObservationParser {
  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    return AgentObservation(activity: Self.detectAmp(screen))
  }

  private static func detectAmp(_ content: String) -> AgentObservation.Activity {
    let lower = content.lowercased()
    let hasWaitingForApproval = lower.contains("waiting for approval")
    let hasApprovalHeader =
      lower.contains("invoke tool")
      || lower.contains("run this command?")
      || lower.contains("allow editing file:")
      || lower.contains("allow creating file:")
      || lower.contains("confirm tool call")
    let hasApprovalActions =
      lower.contains("approve")
      && (lower.contains("allow all for this session")
        || lower.contains("allow all for every session")
        || lower.contains("allow file for every session")
        || lower.contains("deny with feedback"))

    if hasApprovalActions && (hasWaitingForApproval || hasApprovalHeader) {
      return .blocked
    }
    if lower.contains("esc to cancel") {
      return .working
    }
    return .idle
  }

}
