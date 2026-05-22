import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Locks the exact argv each `GhCommand.<method>` produces. These strings cross a process
/// boundary to `gh`, so drift (a missing `--json` field, a reordered flag) is the kind of
/// bug that only surfaces in production. Precedent: exec-plan 0005 DEC-19 — a plumb-through
/// test that did not reach argv masked a flag-vs-pathspec bug.
struct GhCommandTests {
  @Test
  func authStatusArgv() {
    let result = GhCommand.authStatus()
    #expect(result.arguments == ["auth", "status", "--json", "hosts"])
    #expect(result.expectedExitCodes == [0, 1])
  }

  @Test
  func pullRequestViewArgvListsEveryFieldTheUIConsumes() {
    let result = GhCommand.pullRequestView(branch: "feature/github01")
    #expect(result.arguments[0] == "pr")
    #expect(result.arguments[1] == "view")
    #expect(result.arguments[2] == "feature/github01")
    #expect(result.arguments[3] == "--json")
    let fields = result.arguments[4]
    // Every field consumed by PullRequestSnapshot must be on the --json list.
    for required in [
      "number", "title", "state", "isDraft", "headRefName",
      "author", "additions", "deletions", "commits",
      "mergeable", "url", "updatedAt",
    ] {
      #expect(fields.contains(required), "--json must include \(required)")
    }
    #expect(result.expectedExitCodes == [0, 1])
  }

  @Test
  func runListLatestArgv() {
    let result = GhCommand.runListLatest(branch: "main")
    #expect(result.arguments[0..<6] == ["run", "list", "--branch", "main", "--limit", "1"])
    #expect(result.arguments[6] == "--json")
    let fields = result.arguments[7]
    for required in [
      "databaseId", "name", "status", "conclusion",
      "headBranch", "headSha", "number", "updatedAt", "url",
    ] {
      #expect(fields.contains(required))
    }
  }

  @Test
  func pullRequestMergeArgvUsesStrategyCLIFlag() {
    #expect(
      GhCommand.pullRequestMerge(number: 1, strategy: .mergeCommit).arguments
        == ["pr", "merge", "1", "--merge"])
    #expect(
      GhCommand.pullRequestMerge(number: 2, strategy: .squash).arguments
        == ["pr", "merge", "2", "--squash"])
    #expect(
      GhCommand.pullRequestMerge(number: 3, strategy: .rebase).arguments
        == ["pr", "merge", "3", "--rebase"])
  }

  @Test
  func pullRequestCloseArgv() {
    #expect(GhCommand.pullRequestClose(number: 7).arguments == ["pr", "close", "7"])
  }

  @Test
  func pullRequestReadyArgv() {
    #expect(GhCommand.pullRequestReady(number: 11).arguments == ["pr", "ready", "11"])
  }

  @Test
  func runRerunFailedArgv() {
    let result = GhCommand.runRerunFailed(runID: 123_456_789)
    #expect(result.arguments == ["run", "rerun", "123456789", "--failed"])
    #expect(result.expectedExitCodes == [0])
  }
}
