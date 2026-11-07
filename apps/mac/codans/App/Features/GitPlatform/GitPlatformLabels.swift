import CodansCore

/// UI labels that name the Git Platform of a Worktree: "PR" / "MR" and "GitHub" / "GitLab"
/// (ADR 0004 item 4). A Worktree whose Git Platform is not known yet (no fetch has resolved
/// it) keeps the GitHub labels the app used before GitLab support.
enum GitPlatformLabels {
  /// "Open PR on GitHub" / "Open MR on GitLab".
  static func openPullRequest(_ kind: GitPlatformKind?) -> String {
    let kind = kind ?? .github
    return "Open \(kind.pullRequestLabel) on \(kind.displayName)"
  }

  /// "Open Project on GitHub" / "Open Project on GitLab".
  static func openProject(_ kind: GitPlatformKind?) -> String {
    "Open Project on \((kind ?? .github).displayName)"
  }

  /// "Open in GitHub" / "Open in GitLab" (sidebar context menu).
  static func openIn(_ kind: GitPlatformKind?) -> String {
    "Open in \((kind ?? .github).displayName)"
  }

  /// "Open Pull Request" / "Open Merge Request" (sidebar context menu).
  static func openPullRequestLong(_ kind: GitPlatformKind?) -> String {
    "Open \((kind ?? .github).pullRequestName.capitalized)"
  }

  /// "Pull request" / "Merge request", for the start of a sentence.
  static func pullRequestSentence(_ name: String) -> String {
    name.prefix(1).uppercased() + name.dropFirst()
  }

  /// "PR" / "MR".
  static func pullRequest(_ kind: GitPlatformKind?) -> String {
    (kind ?? .github).pullRequestLabel
  }

  /// "#" / "!". SwiftUI `Text` call sites interpolate the number after this prefix
  /// themselves, so the number keeps its locale grouping (`#14,846`).
  static func referencePrefix(_ kind: GitPlatformKind?) -> String {
    (kind ?? .github).referencePrefix
  }

  /// "#6" / "!6", for plain strings such as toasts.
  static func reference(_ kind: GitPlatformKind?, number: Int) -> String {
    "\(referencePrefix(kind))\(number)"
  }
}

extension GitPlatformFeature.State {
  /// The Git Platform of a Worktree's fetch unit, from its latest batch.
  func gitPlatformKind(for worktreeID: WorktreeID?) -> GitPlatformKind? {
    worktreeID.flatMap { repository(for: $0)?.kind }
  }

  /// The Git Platform of a Project: its own fetch unit's batch, or the batch of any of its
  /// Worktrees (a Workspace member's unit).
  func gitPlatformKind(forProject projectID: ProjectID?, worktreeID: WorktreeID?) -> GitPlatformKind? {
    gitPlatformKind(for: worktreeID) ?? projectID.flatMap { snapshotsByProject[$0]?.repository.kind }
  }
}
