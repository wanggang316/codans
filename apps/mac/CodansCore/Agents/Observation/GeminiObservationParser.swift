import Foundation

nonisolated struct GeminiObservationParser: AgentTerminalParser {
  func parse(_ text: String) -> TerminalParseResult {
    let screen = AgentObservationText.interactionLines(text, promptPrefixes: ["gemini>"]).joined(separator: "\n")
    return AgentObservationText.result(activity: Self.detectGemini(screen), text: screen, promptPrefixes: ["gemini>"])
  }

  private static func detectGemini(_ content: String) -> AgentObservedActivity {
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
    return .unknown
  }

}
