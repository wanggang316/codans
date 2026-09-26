import Foundation

nonisolated struct KimiObservationParser: AgentObservationParser {
  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    return AgentObservation(activity: Self.detectKimi(screen))
  }

  private static func detectKimi(_ content: String) -> AgentObservation.Activity {
    let lower = content.lowercased()
    let blockedPatterns = [
      "allow?", "confirm?", "approve?", "proceed?", "[y/n]", "(y/n)",
    ]
    if blockedPatterns.contains(where: lower.contains)
      || AgentObservationText.hasConfirmationPrompt(lower)
      || hasKimiApprovalPanel(content: content, lower: lower)
    {
      return .blocked
    }

    let workingPatterns = [
      "thinking", "processing", "generating", "waiting for response",
      "ctrl+c to cancel", "ctrl-c to cancel",
    ]
    if workingPatterns.contains(where: lower.contains)
      || hasKimiMoonSpinner(content)
      || hasKimiToolSpinner(content: content, lower: lower)
    {
      return .working
    }
    return .idle
  }

  private static func hasKimiApprovalPanel(content: String, lower: String) -> Bool {
    lower.contains("requesting approval")
      || (lower.contains("approve once") && lower.contains("approve for this session")
        && lower.contains("reject"))
      || (content.contains("─ approval") && content.contains("↵ confirm"))
  }

  private static func hasKimiMoonSpinner(_ content: String) -> Bool {
    let moonSpinners: Set<Character> = ["🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘"]
    return content.contains { moonSpinners.contains($0) }
  }

  private static func hasKimiToolSpinner(content: String, lower: String) -> Bool {
    guard lower.contains("using ") else { return false }
    return content.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let first = trimmed.unicodeScalars.first else { return false }
      return (0x2800...0x28FF).contains(Int(first.value))
    }
  }

}
