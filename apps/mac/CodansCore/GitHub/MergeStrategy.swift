import Foundation

/// How a pull request is merged on the remote. Maps 1:1 to `gh pr merge` flags.
///
/// Raw values are lowercase English tokens written to `settings.json` — the merge flag
/// string that's passed to `gh` at runtime is exposed via `cliFlag`, separately so the
/// wire form and the CLI form can evolve independently.
public enum MergeStrategy: String, Codable, Sendable, CaseIterable {
  case mergeCommit = "merge_commit"
  case squash = "squash"
  case rebase = "rebase"

  /// Flag argument passed to `gh pr merge`. `gh` accepts `--merge`, `--squash`, `--rebase`.
  public var cliFlag: String {
    switch self {
    case .mergeCommit: return "--merge"
    case .squash: return "--squash"
    case .rebase: return "--rebase"
    }
  }

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
