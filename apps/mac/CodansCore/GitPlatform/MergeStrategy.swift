import Foundation

/// How a Pull Request is merged on the Git Platform.
///
/// Raw values are lowercase English tokens written to `settings.json`. Each Git Platform
/// implementation maps a strategy to its own CLI form.
public enum MergeStrategy: String, Codable, Sendable, CaseIterable {
  case mergeCommit = "merge_commit"
  case squash = "squash"
  case rebase = "rebase"

  /// User-facing label for pickers and buttons. Uppercase style matches the popover's
  /// "Merge (squash)" shape — the concrete view wraps this with "Merge (…)".
  public var displayName: String {
    switch self {
    case .mergeCommit: return "Create merge commit"
    case .squash: return "Squash and merge"
    case .rebase: return "Rebase and merge"
    }
  }

  /// Short label for the split-button primary face ("Merge (squash)"). Keeps the button
  /// compact while the full displayName lives in the caret picker.
  public var shortName: String {
    switch self {
    case .mergeCommit: return "merge"
    case .squash: return "squash"
    case .rebase: return "rebase"
    }
  }
}
