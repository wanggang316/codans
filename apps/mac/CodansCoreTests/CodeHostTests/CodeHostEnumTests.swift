import Foundation
import Testing

@testable import CodansCore

struct CodeHostEnumTests {
  // MARK: - MergeStrategy

  @Test
  func mergeStrategyRawValues() {
    #expect(MergeStrategy.mergeCommit.rawValue == "merge_commit")
    #expect(MergeStrategy.squash.rawValue == "squash")
    #expect(MergeStrategy.rebase.rawValue == "rebase")
  }

  @Test
  func mergeStrategyDisplayNames() {
    #expect(MergeStrategy.mergeCommit.displayName == "Create merge commit")
    #expect(MergeStrategy.squash.displayName == "Squash and merge")
    #expect(MergeStrategy.rebase.displayName == "Rebase and merge")
  }

  @Test
  func mergeStrategyShortNames() {
    #expect(MergeStrategy.mergeCommit.shortName == "merge")
    #expect(MergeStrategy.squash.shortName == "squash")
    #expect(MergeStrategy.rebase.shortName == "rebase")
  }

  @Test
  func mergeStrategyRoundTrip() throws {
    for strategy in MergeStrategy.allCases {
      let data = try JSONEncoder().encode(strategy)
      let decoded = try JSONDecoder().decode(MergeStrategy.self, from: data)
      #expect(decoded == strategy)
    }
  }

  // MARK: - CodeHostKind

  @Test
  func githubKindLabels() {
    #expect(CodeHostKind.github.rawValue == "github")
    #expect(CodeHostKind.github.displayName == "GitHub")
    #expect(CodeHostKind.github.pullRequestLabel == "PR")
    #expect(CodeHostKind.github.publicHost == "github.com")
    #expect(CodeHostKind.github.cliName == "gh")
  }

  @Test
  func gitlabKindLabels() {
    #expect(CodeHostKind.gitlab.rawValue == "gitlab")
    #expect(CodeHostKind.gitlab.displayName == "GitLab")
    #expect(CodeHostKind.gitlab.pullRequestLabel == "MR")
    #expect(CodeHostKind.gitlab.pullRequestName == "merge request")
    #expect(CodeHostKind.gitlab.repositoryName == "Project")
    #expect(CodeHostKind.gitlab.publicHost == "gitlab.com")
    #expect(CodeHostKind.gitlab.cliName == "glab")
    #expect(CodeHostKind.github.pullRequestName == "pull request")
    #expect(CodeHostKind.github.repositoryName == "Repository")
  }

  /// GitHub is tried first, so a host known to both CLIs resolves to GitHub.
  @Test
  func kindsAreTriedGitHubFirst() {
    #expect(CodeHostKind.allCases == [.github, .gitlab])
  }

  // MARK: - Merge strategy selection

  private func snapshot(options: [PullRequestMergeOption]) -> PullRequestSnapshot {
    PullRequestSnapshot(
      number: 1, title: "t", state: .open, isDraft: false, headRefName: "b", author: "a",
      additions: 0, deletions: 0, commitCount: 1, url: URL(string: "https://example.com")!,
      updatedAt: Date(timeIntervalSince1970: 0), mergeOptions: options)
  }

  /// GitLab offers Merge and Squash and merge: `mergeCommit` and `rebase` map to Merge,
  /// `squash` to Squash and merge (ADR 0004 item 6).
  @Test
  func mergeStrategyFallsBackToPlainMergeWhenNotOffered() {
    let gitlab = snapshot(options: [
      PullRequestMergeOption(strategy: .mergeCommit, isEnabled: true, label: "Merge"),
      PullRequestMergeOption(strategy: .squash, isEnabled: false, disabledReason: "no"),
    ])
    #expect(gitlab.mergeStrategy(preferring: .mergeCommit) == .mergeCommit)
    #expect(gitlab.mergeStrategy(preferring: .rebase) == .mergeCommit)
    #expect(gitlab.mergeStrategy(preferring: .squash) == .squash)
    let github = snapshot(
      options: MergeStrategy.allCases.map { PullRequestMergeOption(strategy: $0, isEnabled: true) })
    #expect(github.mergeStrategy(preferring: .rebase) == .rebase)
    #expect(snapshot(options: []).mergeStrategy(preferring: .rebase) == .rebase)
  }

  @Test
  func mergeOptionDisplayNamePrefersLabel() {
    #expect(PullRequestMergeOption(strategy: .mergeCommit, isEnabled: true, label: "Merge").displayName == "Merge")
    #expect(PullRequestMergeOption(strategy: .squash, isEnabled: true).displayName == "Squash and merge")
  }

  @Test
  func repositoryPathSegmentsKeepNestedGroups() {
    let repository = CodeHostRepository(kind: .github, host: "example.com", path: "group/sub/repo")
    #expect(repository.pathSegments == ["group", "sub", "repo"])
  }

  // MARK: - MergedWorktreeAction

  @Test
  func mergedWorktreeActionRawValues() {
    #expect(MergedWorktreeAction.doNothing.rawValue == "do_nothing")
    #expect(MergedWorktreeAction.archive.rawValue == "archive")
    #expect(MergedWorktreeAction.delete.rawValue == "delete")
    #expect(MergedWorktreeAction.ask.rawValue == "ask")
  }

  @Test
  func mergedWorktreeActionDisplayNames() {
    #expect(MergedWorktreeAction.doNothing.displayName == "Do nothing")
    #expect(MergedWorktreeAction.archive.displayName == "Archive the worktree")
    #expect(MergedWorktreeAction.delete.displayName == "Delete the worktree")
    #expect(MergedWorktreeAction.ask.displayName == "Ask each time")
  }

  @Test
  func mergedWorktreeActionRoundTrip() throws {
    for action in MergedWorktreeAction.allCases {
      let data = try JSONEncoder().encode(action)
      let decoded = try JSONDecoder().decode(MergedWorktreeAction.self, from: data)
      #expect(decoded == action)
    }
  }
}
