import Foundation

nonisolated struct GrokObservationParser: AgentObservationParser {
  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    return AgentObservation(activity: Self.detectGenericInterruptCue(screen))
  }

  /// Fallback classifier for agents whose TUI we have not profiled yet: the
  /// two cues almost every CLI agent renders — a yes/no confirmation prompt
  /// (blocked) and an "esc to interrupt / cancel" hint (working). Less
  /// precise than a hand-tuned detector, but it keeps the badge honest
  /// instead of pinning a live agent on idle.
  private static func detectGenericInterruptCue(_ content: String) -> AgentObservation.Activity {
    let lower = content.lowercased()
    if AgentObservationText.hasConfirmationPrompt(lower) || lower.contains("[y/n]") || lower.contains("(y/n)") {
      return .blocked
    }
    if AgentObservationText.hasInterruptPattern(lower) || lower.contains("esc to cancel")
      || lower.contains("esc to stop")
    {
      return .working
    }
    return .idle
  }

}
