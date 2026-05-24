import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Argv-ordering tests for `GitCommand`. Added after the 0005 M4a.1 review caught a bug
/// where `-w` was appended AFTER `--` for `.commit`, turning it into a pathspec named `-w`
/// instead of an ignore-whitespace flag. Tests now lock the ordering contract per call site.
struct GitCommandTests {
  @Test
  func workingTreeDiffWithoutWhitespaceFlag() {
    let argv = GitCommand.diff(kind: .workingTree)
    #expect(
      argv == [
        "-c", "core.quotePath=false",
        "diff", "--no-color", "--no-ext-diff", "-M", "-C", "-U3",
      ])
  }

  @Test
  func workingTreeDiffWithIgnoreWhitespacePlacesFlagBeforeEnd() {
    let argv = GitCommand.diff(kind: .workingTree, ignoreWhitespace: true)
    #expect(argv.last == "-w")
    #expect(argv.contains("-w"))
  }

  @Test
  func stagedDiffIncludesCachedFlag() {
    let argv = GitCommand.diff(kind: .staged)
    #expect(argv.contains("--cached"))
    #expect(!argv.contains("-w"))
  }

  @Test
  func stagedDiffWithWhitespaceFlagFollowsCached() {
    let argv = GitCommand.diff(kind: .staged, ignoreWhitespace: true)
    let cachedIdx = argv.firstIndex(of: "--cached")!
    let whitespaceIdx = argv.firstIndex(of: "-w")!
    #expect(cachedIdx < whitespaceIdx, "--cached should come before -w in the flag stream")
  }

  @Test
  func commitDiffEndsWithShaAndDashDash() {
    let argv = GitCommand.diff(kind: .commit(sha: "abc1234"))
    // The trailer must be `sha, "--"` so git interprets the remaining arg as an rev + no
    // paths. The bug the review caught had `-w` landing after `--`.
    #expect(argv.suffix(2) == ["abc1234", "--"])
    #expect(argv.contains("show"))
    #expect(argv.contains("--format="))
  }

  /// **Critical bug guard (0005 M4a.1).** Ensures `-w` lands BEFORE the `--` separator for
  /// the commit scope. Git treats tokens after `--` as pathspec, so a misplaced `-w` would
  /// silently turn into a filter for a path literally named `-w` rather than enabling
  /// ignore-whitespace.
  @Test
  func commitDiffWithIgnoreWhitespacePlacesFlagBeforeDashDash() {
    let argv = GitCommand.diff(kind: .commit(sha: "abc1234"), ignoreWhitespace: true)
    let whitespaceIdx = argv.firstIndex(of: "-w")!
    let dashDashIdx = argv.firstIndex(of: "--")!
    #expect(
      whitespaceIdx < dashDashIdx,
      "-w must precede `--`; otherwise git interprets it as a pathspec named -w")
    // And the sha + "--" pair must still sit at the tail.
    #expect(argv.suffix(2) == ["abc1234", "--"])
  }

  @Test
  func logArgvIncludesPrettyFormatWithNullDelimiters() {
    let argv = GitCommand.log(limit: 100, skip: 0)
    #expect(argv.contains("log"))
    #expect(argv.contains("-z"))
    // Pretty format should include the six fields separated by %x00.
    #expect(argv.contains(where: { $0.contains("%x00") }))
  }

  @Test
  func logSkipAppendedOnlyWhenNonZero() {
    let noSkip = GitCommand.log(limit: 100, skip: 0)
    #expect(!noSkip.contains("--skip"))

    let withSkip = GitCommand.log(limit: 100, skip: 200)
    let skipIdx = withSkip.firstIndex(of: "--skip")!
    #expect(withSkip[skipIdx + 1] == "200")
  }

  @Test
  func statusArgvIsStablePorcelainV1WithUntrackedAll() {
    let argv = GitCommand.status()
    #expect(
      argv == [
        "-c", "core.quotePath=false",
        "status", "--porcelain=v1", "-z", "--untracked-files=all",
      ])
  }

  @Test
  func revParseIsInsideWorkTreeHasNoExtraFlags() {
    let argv = GitCommand.revParseIsInsideWorkTree()
    #expect(argv == ["rev-parse", "--is-inside-work-tree"])
  }

  @Test
  func everyDiffArgvBeginsWithQuotePathFalse() {
    for kind: GitCommand.DiffKind in [.workingTree, .staged, .commit(sha: "deadbeef")] {
      let argv = GitCommand.diff(kind: kind)
      #expect(argv[0] == "-c")
      #expect(argv[1] == "core.quotePath=false")
    }
  }

  @Test
  func symbolicRefShortHeadArgvIsExact() {
    #expect(GitCommand.symbolicRefShortHead() == ["symbolic-ref", "--short", "HEAD"])
  }

  @Test
  func forEachRefBranchesIncludesBothRefRoots() {
    let argv = GitCommand.forEachRefBranches()
    #expect(argv.contains("refs/heads"))
    #expect(argv.contains("refs/remotes"))
    let formatToken = argv.first(where: { $0.hasPrefix("--format=") })
    #expect(formatToken != nil)
    if let formatToken {
      #expect(formatToken.contains("%(refname)"))
      #expect(formatToken.contains("%(refname:short)"))
      #expect(formatToken.contains("%(upstream:short)"))
      #expect(formatToken.contains("%(HEAD)"))
    }
  }

  @Test
  func forEachRefBranchesQuotePathDisabled() {
    let argv = GitCommand.forEachRefBranches()
    #expect(Array(argv.prefix(3)) == ["-c", "core.quotePath=false", "for-each-ref"])
  }

  @Test
  func switchBranchLocalArgvIsExact() {
    #expect(GitCommand.switchBranch(target: .local(name: "main")) == ["switch", "main"])
  }

  @Test
  func switchBranchRemoteTrackingArgvIsExact() {
    #expect(
      GitCommand.switchBranch(target: .remoteTracking(shortName: "origin/feat/x"))
        == ["switch", "--track", "origin/feat/x"])
  }

  @Test
  func switchBranchDoesNotCreate() {
    let targets: [BranchSwitchTarget] = [
      .local(name: "main"),
      .remoteTracking(shortName: "origin/feat/x"),
    ]
    for target in targets {
      let argv = GitCommand.switchBranch(target: target)
      #expect(!argv.contains("--create"), "switch argv must not contain `--create`")
      // `-c` as the `--create` short flag only appears AFTER the `switch` subcommand;
      // any `-c` BEFORE `switch` is git's config-override flag and is allowed.
      if let switchIdx = argv.firstIndex(of: "switch") {
        let trailing = argv.dropFirst(switchIdx + 1)
        #expect(
          !trailing.contains("-c"),
          "switch argv must not contain `-c` after the subcommand (the --create short flag)"
        )
      }
    }
  }

  @Test
  func forEachRefBranchesArgvIsExact() {
    #expect(
      GitCommand.forEachRefBranches() == [
        "-c", "core.quotePath=false",
        "for-each-ref",
        "--format=%(refname)%09%(refname:short)%09%(upstream:short)%09%(HEAD)",
        "refs/heads", "refs/remotes",
      ])
  }
}
