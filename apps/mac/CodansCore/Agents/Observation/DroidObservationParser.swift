import Foundation

nonisolated struct DroidObservationParser: AgentObservationParser {
  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    return AgentObservation(activity: Self.detectDroid(screen))
  }

  private static func detectDroid(_ content: String) -> AgentObservation.Activity {
    let lower = content.lowercased()
    let hasExecute = content.contains("EXECUTE")
    let hasSelectionChrome =
      lower.contains("enter to select")
      || lower.contains("↑↓ to navigate")
      || lower.contains("esc to cancel")
    let hasSelectionOptions =
      lower.contains("> yes, allow")
      || lower.contains("> no, cancel")

    if hasExecute && (hasSelectionChrome || hasSelectionOptions) {
      return .blocked
    }
    if hasSelectionChrome && hasSelectionOptions {
      return .blocked
    }
    if hasDroidSpinner(content) || lower.contains("esc to stop") {
      return .working
    }
    return .idle
  }

  private static func hasDroidSpinner(_ content: String) -> Bool {
    content.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
      guard let first = trimmed.unicodeScalars.first else { return false }
      return (0x2800...0x28FF).contains(Int(first.value)) && trimmed.contains("esc to stop")
    }
  }

}
