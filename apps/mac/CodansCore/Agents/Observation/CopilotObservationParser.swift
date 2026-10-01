import Foundation

nonisolated struct CopilotObservationParser: AgentTerminalParser {
  func parse(_ text: String) -> TerminalParseResult {
    let screen = AgentObservationText.interactionLines(text, promptPrefixes: ["copilot>"]).joined(separator: "\n")
    return AgentObservationText.result(activity: Self.detectCopilot(screen), text: screen, promptPrefixes: ["copilot>"])
  }

  private static func detectCopilot(_ content: String) -> AgentObservedActivity {
    let lower = content.lowercased()
    if lower.contains("│ do you want")
      || (lower.contains("confirm with") && lower.contains("enter"))
    {
      return .blocked
    }
    if lower.contains("esc to cancel") {
      return .working
    }
    return .unknown
  }

}
