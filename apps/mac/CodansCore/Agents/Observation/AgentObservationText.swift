import Foundation

nonisolated enum AgentObservationText {
  static let recentLineLimit = 24

  static func recentAgentLines(_ content: String, limit: Int) -> String {
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else { return "" }
    var remainingNonBlankLines = limit
    var startIndex = lines.startIndex

    for index in lines.indices.reversed() {
      guard !lines[index].trimmingCharacters(in: .whitespaces).isEmpty else {
        continue
      }
      remainingNonBlankLines -= 1
      if remainingNonBlankLines == 0 {
        startIndex = index
        break
      }
    }

    return lines[startIndex...].joined(separator: "\n")
  }

  static func hasConfirmationPrompt(_ lower: String) -> Bool {
    guard
      let range = lower.range(of: "do you want") ?? lower.range(of: "would you like")
    else {
      return false
    }
    let after = lower[range.lowerBound...]
    return after.contains("yes") || after.contains("❯")
  }

  static func hasInterruptPattern(_ lower: String) -> Bool {
    lower.contains("esc to interrupt")
      || lower.contains("ctrl+c to interrupt")
      || (lower.contains("esc") && lower.contains("interrupt"))
  }

  static func trailingErrorLine(_ text: String) -> String? {
    let lines = recentAgentLines(text, limit: AgentObservationText.recentLineLimit)
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let lower = lines.joined(separator: "\n").lowercased()
    // Provider-owned retries must finish before an external recovery intervenes.
    if lower.contains("```") || lower.contains("retrying") || lower.contains("reconnecting")
      || lower.contains("attempting to reconnect") || lower.contains("retry in ")
    {
      return nil
    }
    let trailing = lines.reversed().drop { line in
      line == "❯" || line == "›" || line == "codex>"
        || (line.count >= 3 && line.allSatisfy { $0 == "─" || $0 == "━" })
    }
    guard let line = trailing.first else { return nil }
    return line
  }
}
