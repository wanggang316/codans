import CodansCore

/// UI labels that name the Code Host of a Worktree: "PR" / "MR" and "GitHub" / "GitLab"
/// (ADR 0004 item 4). A Worktree whose Code Host is not known yet (no fetch has resolved
/// it) keeps the GitHub labels the app used before GitLab support.
enum CodeHostLabels {
  /// "Open PR on GitHub" / "Open MR on GitLab".
  static func openPullRequest(_ kind: CodeHostKind?) -> String {
    let kind = kind ?? .github
    return "Open \(kind.pullRequestLabel) on \(kind.displayName)"
  }

  /// "Open Project on GitHub" / "Open Project on GitLab".
  static func openProject(_ kind: CodeHostKind?) -> String {
    "Open Project on \((kind ?? .github).displayName)"
  }

  /// "Open in GitHub" / "Open in GitLab" (sidebar context menu).
  static func openIn(_ kind: CodeHostKind?) -> String {
    "Open in \((kind ?? .github).displayName)"
  }

  /// "Open Pull Request" / "Open Merge Request" (sidebar context menu).
  static func openPullRequestLong(_ kind: CodeHostKind?) -> String {
    "Open \((kind ?? .github).pullRequestName.capitalized)"
  }

  /// "Pull request" / "Merge request", for the start of a sentence.
  static func pullRequestSentence(_ name: String) -> String {
    name.prefix(1).uppercased() + name.dropFirst()
  }

  /// "PR" / "MR".
  static func pullRequest(_ kind: CodeHostKind?) -> String {
    (kind ?? .github).pullRequestLabel
  }
}

extension CodeHostFeature.State {
  /// The Code Host of a Worktree's fetch unit, from its latest batch.
  func codeHostKind(for worktreeID: WorktreeID?) -> CodeHostKind? {
    worktreeID.flatMap { repository(for: $0)?.kind }
  }

  /// The Code Host of a Project: its own fetch unit's batch, or the batch of any of its
  /// Worktrees (a Workspace member's unit).
  func codeHostKind(forProject projectID: ProjectID?, worktreeID: WorktreeID?) -> CodeHostKind? {
    codeHostKind(for: worktreeID) ?? projectID.flatMap { snapshotsByProject[$0]?.repository.kind }
  }
}
