import Foundation
import Testing
import CodansCore

@testable import Codans

/// Locks the exact argv each `GhCommand.<method>` produces. These strings cross a process
/// boundary to `gh`, so drift (a missing `--json` field, a reordered flag) is the kind of
/// bug that only surfaces in production. Precedent: a plumb-through
/// test that did not reach argv masked a flag-vs-pathspec bug.
struct GhCommandTests {
  @Test
  func authStatusArgv() {
    let result = GhCommand.authStatus()
    #expect(result.arguments == ["auth", "status", "--json", "hosts"])
    #expect(result.expectedExitCodes == [0, 1])
  }

  @Test
  func pullRequestCheckRollupArgv() {
    let result = GhCommand.pullRequestCheckRollup(number: 42, repo: "github.com/o/r")
    #expect(result.arguments == ["pr", "view", "42", "--repo", "github.com/o/r", "--json", "statusCheckRollup"])
    #expect(result.expectedExitCodes == [0])
  }

  @Test
  func pullRequestMergeArgvUsesStrategyCLIFlag() {
    #expect(
      GhCommand.pullRequestMerge(number: 1, strategy: .mergeCommit, repo: "h/o/r").arguments
        == ["pr", "merge", "1", "--merge", "--repo", "h/o/r"])
    #expect(
      GhCommand.pullRequestMerge(number: 2, strategy: .squash, repo: "h/o/r").arguments
        == ["pr", "merge", "2", "--squash", "--repo", "h/o/r"])
    #expect(
      GhCommand.pullRequestMerge(number: 3, strategy: .rebase, repo: "h/o/r").arguments
        == ["pr", "merge", "3", "--rebase", "--repo", "h/o/r"])
  }

  @Test
  func mergeFlags() {
    #expect(GhCommand.mergeFlag(.mergeCommit) == "--merge")
    #expect(GhCommand.mergeFlag(.squash) == "--squash")
    #expect(GhCommand.mergeFlag(.rebase) == "--rebase")
  }

  @Test
  func pullRequestCloseArgv() {
    #expect(
      GhCommand.pullRequestClose(number: 7, repo: "h/o/r").arguments
        == ["pr", "close", "7", "--repo", "h/o/r"])
  }

  @Test
  func pullRequestReadyArgv() {
    #expect(
      GhCommand.pullRequestReady(number: 11, repo: "h/o/r").arguments
        == ["pr", "ready", "11", "--repo", "h/o/r"])
  }

  @Test
  func runRerunFailedArgv() {
    let result = GhCommand.runRerunFailed(runID: 123_456_789, repo: "h/o/r")
    #expect(result.arguments == ["run", "rerun", "123456789", "--failed", "--repo", "h/o/r"])
    #expect(result.expectedExitCodes == [0])
  }

  @Test
  func repoArgumentKeepsTheHostForGHES() {
    let repository = CodeHostRepository(kind: .github, host: "ghe.example.com", path: "platform/monorepo")
    #expect(GitHub.repoArgument(repository) == "ghe.example.com/platform/monorepo")
  }
}
