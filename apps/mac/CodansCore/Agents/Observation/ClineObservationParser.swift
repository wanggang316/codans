import Foundation

nonisolated struct ClineObservationParser: AgentObservationParser {
  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    return AgentObservation(activity: Self.detectCline(screen))
  }

  private static func detectCline(_ content: String) -> AgentObservation.Activity {
    let lower = content.lowercased()
    if lower.contains("let cline use this tool")
      || ((lower.contains("[act mode]") || lower.contains("[plan mode]")) && lower.contains("yes"))
      || hasClineNumberedChoicePrompt(content)
    {
      return .blocked
    }
    if AgentObservationText.hasInterruptPattern(lower) {
      return .working
    }
    return .idle
  }

  private static func hasClineNumberedChoicePrompt(_ content: String) -> Bool {
    content.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
      guard let suffix = line.range(of: " or type)") else { return false }
      let prefix = line[..<suffix.lowerBound]
      guard let openParen = prefix.lastIndex(of: "(") else { return false }
      let between = prefix[prefix.index(after: openParen)...]
      return between.contains("-") && between.allSatisfy { $0.isNumber || $0 == "-" }
    }
  }

}
