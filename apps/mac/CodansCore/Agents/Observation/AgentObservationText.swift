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

  /// Strip quoted/code content before matching provider chrome. This reduces
  /// accidental transcript matches; exact forged chrome is not authenticatable.
  static func unquotedLines(_ text: String) -> [String] {
    var inFence = false
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") || line.hasPrefix("~~~") {
        inFence.toggle()
        return ""
      }
      let selector = ["> yes, allow", "> no, cancel"].contains { line.lowercased().hasPrefix($0) }
      if inFence || (line.hasPrefix("> ") && !selector) || line.hasPrefix("│ > ") { return "" }
      return line
    }
  }

  static func isBorder(_ line: String) -> Bool {
    !line.isEmpty && line.allSatisfy { "─━-╭╮╰╯│┌┐└┘".contains($0) }
  }

  static func promptContent(_ line: String, prefixes: [String]) -> AgentPromptContent? {
    for prefix in prefixes where line == prefix || line.hasPrefix(prefix + " ") {
      let content = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
      return content.isEmpty ? .empty : .occupied
    }
    return nil
  }

  static func inputAvailability(_ lines: [String], prefixes: [String]) -> AgentInputAvailability {
    guard let last = lines.last(where: { !$0.isEmpty && !isBorder($0) }),
      let content = promptContent(last, prefixes: prefixes)
    else { return .unknown }
    return .prompt(content)
  }

  /// A submitted prompt before the current composer establishes an interaction
  /// boundary. With no such boundary, matching remains deliberately conservative.
  static func interactionLines(_ text: String, promptPrefixes: [String]) -> [String] {
    let lines = unquotedLines(text)
    let prompts = lines.indices.filter { promptContent(lines[$0], prefixes: promptPrefixes) != nil }
    let start: Int
    if prompts.count >= 2 { start = prompts[prompts.count - 2] + 1 } else { start = lines.startIndex }
    let region = lines[start...].joined(separator: "\n")
    return recentAgentLines(region, limit: recentLineLimit).split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
  }

  static func result(activity: AgentObservedActivity, text: String, promptPrefixes: [String]) -> TerminalParseResult {
    let input = inputAvailability(unquotedLines(text), prefixes: promptPrefixes)
    switch activity {
    case .working: return .working()
    case .blocked: return .blocked()
    default:
      if case .prompt = input { return .idle(inputAvailability: input) }
      return .unknown()
    }
  }
}
