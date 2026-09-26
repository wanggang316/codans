import Foundation

nonisolated struct CursorObservationParser: AgentObservationParser {
  func parse(_ text: String) -> AgentObservation {
    let screen = AgentObservationText.recentAgentLines(
      text, limit: AgentObservationText.recentLineLimit)
    return AgentObservation(activity: Self.detectCursor(screen))
  }

  private static func detectCursor(_ content: String) -> AgentObservation.Activity {
    let lower = content.lowercased()
    if lower.contains("workspace trust required")
      || lower.contains("trust this workspace")
      || hasCursorPermissionPrompt(content: content, lower: lower)
    {
      return .blocked
    }
    if lower.contains("trusting workspace") || lower.contains("ctrl+c to stop")
      || hasCursorSpinner(content)
    {
      return .working
    }
    return .idle
  }

  private static func hasCursorPermissionPrompt(content: String, lower: String) -> Bool {
    if lower.contains("(y) (enter)") {
      return true
    }

    let hasPermissionHeader =
      lower.contains("run this command?")
      || lower.contains("run command?")
      || lower.contains("not in allowlist")
      || lower.contains("to allowlist?")
      || lower.contains("allow execution")
    guard hasPermissionHeader else { return false }

    let hasConfirmAction = content.split(separator: "\n", omittingEmptySubsequences: false)
      .contains { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.contains("(y)") else { return false }
        return trimmed.contains("run") || trimmed.contains("allow")
      }
    let hasCancelAction =
      lower.contains("skip (esc or n)")
      || lower.contains("keep (n)")

    return hasConfirmAction || hasCancelAction
  }

  private static func hasCursorSpinner(_ content: String) -> Bool {
    content.split(separator: "\n").contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
      return (trimmed.hasPrefix("⬡") || trimmed.hasPrefix("⬢")) && trimmed.contains("ing")
    }
  }

}
