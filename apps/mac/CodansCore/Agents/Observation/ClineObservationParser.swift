import Foundation

nonisolated struct ClineObservationParser: AgentTerminalParser {
  func parse(_ text: String) -> TerminalParseResult {
    let screen = AgentObservationText.interactionLines(text, promptPrefixes: ["cline>"]).joined(separator: "\n")
    return AgentObservationText.result(activity: Self.detectCline(screen), text: screen, promptPrefixes: ["cline>"])
  }

  private static func detectCline(_ content: String) -> AgentObservedActivity {
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
    return .unknown
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
