import CodansCore
import Foundation

/// Pure formatting for an Agents View row's activity text, kept off the
/// view so it stays unit-testable without rendering.
nonisolated enum AgentActivityFormat {
  /// Activity text worth showing: trimmed, non-empty, and saying more than
  /// the agent's own name (idle agents set the pane title to themselves).
  static func activityLine(from text: String?, kind: AgentKind) -> String? {
    guard
      let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty,
      !isRedundantActivityTitle(raw, agentDisplayName: kind.displayName)
    else { return nil }
    return raw
  }

  /// The row's first line: the activity text, else the agent display name.
  static func rowText(from text: String?, kind: AgentKind) -> String {
    activityLine(from: text, kind: kind) ?? kind.displayName
  }

  /// True when a title carries no information beyond the agent's display
  /// name — idle agents typically retitle the pane to themselves
  /// (`Claude Code`, `✳ Claude Code`). Leading decoration (spinner glyphs,
  /// punctuation, whitespace) is stripped before the case-insensitive
  /// comparison; anything longer than the bare name (e.g.
  /// "✳ Claude Code · fixing tests") is information and stays.
  static func isRedundantActivityTitle(_ title: String, agentDisplayName: String) -> Bool {
    var stripped = Substring(title)
    while let first = stripped.first, !first.isLetter, !first.isNumber {
      stripped.removeFirst()
    }
    return stripped.trimmingCharacters(in: .whitespaces)
      .caseInsensitiveCompare(agentDisplayName) == .orderedSame
  }
}
