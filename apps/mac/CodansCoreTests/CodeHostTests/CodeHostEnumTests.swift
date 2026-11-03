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
