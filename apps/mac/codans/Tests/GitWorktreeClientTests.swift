import Foundation
import Testing

@testable import Codans

/// Pure-helper coverage for `GitWorktreeClient`. The closures themselves
/// are exercised by the integration test against a real git repo;
/// here we lock the argument-builder matrix, JSON decode, sanitizer,
/// and stderr mapping so regressions surface without spawning processes.
struct GitWorktreeClientTests {
  // MARK: - sanitizeBranchName

  @Test
  func sanitizePreservesSlashAsPathSeparator() {
    // `feature/abc` maps to nested folders `feature/abc`, not
    // a flattened `feature-abc`. The full branch path is the relative
    // directory path under the project's worktree base.
    #expect(GitWorktreeClient.sanitizeBranchName("feature/login") == "feature/login")
    #expect(GitWorktreeClient.sanitizeBranchName("feature/a/b") == "feature/a/b")
  }

  @Test
  func sanitizeStripsUnsafeCharacters() {
    #expect(GitWorktreeClient.sanitizeBranchName("weird:name") == "weirdname")
    #expect(GitWorktreeClient.sanitizeBranchName("back\\slash") == "backslash")
  }

  @Test
  func sanitizeCollapsesRepeatedDashesPerSegment() {
    #expect(GitWorktreeClient.sanitizeBranchName("feature--name") == "feature-name")
    #expect(GitWorktreeClient.sanitizeBranchName("a--/b--c") == "a/b-c")
  }

  @Test
  func sanitizeCollapsesRepeatedSlashes() {
    #expect(GitWorktreeClient.sanitizeBranchName("a///b") == "a/b")
  }

  @Test
  func sanitizeTrimsBoundaryDashesPerSegment() {
    #expect(GitWorktreeClient.sanitizeBranchName("---trim---") == "trim")
    #expect(GitWorktreeClient.sanitizeBranchName("/feature/") == "feature")
    #expect(GitWorktreeClient.sanitizeBranchName("-feature/-abc-") == "feature/abc")
  }

  @Test
  func sanitizePassesThroughPlainNames() {
    #expect(GitWorktreeClient.sanitizeBranchName("plain") == "plain")
    #expect(GitWorktreeClient.sanitizeBranchName("with-dashes") == "with-dashes")
  }

  // MARK: - makeCreateArguments

  @Test
  func createArgsNoCopyFlagsNoVerbose() {
    let spec = CreateWorktreeSpec(
      repoRoot: URL(fileURLWithPath: "/repo"),
      baseDirectory: URL(fileURLWithPath: "/base"),
      name: "feature-login",
      baseRef: "origin/main",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
    #expect(
      GitWorktreeClient.makeCreateArguments(for: spec) == [
        "--base-dir", "/base",
        "sw",
        "--from", "origin/main",
        "feature-login",
      ])
  }

  @Test
  func createArgsCopyIgnoredIncludesVerbose() {
    let spec = CreateWorktreeSpec(
      repoRoot: URL(fileURLWithPath: "/repo"),
      baseDirectory: URL(fileURLWithPath: "/base"),
      name: "feature",
      baseRef: "main",
      fetchOrigin: false,
      copyIgnored: true,
      copyUntracked: false
    )
    #expect(
      GitWorktreeClient.makeCreateArguments(for: spec) == [
        "--base-dir", "/base",
        "sw",
        "--copy-ignored",
        "--from", "main",
        "--verbose",
        "feature",
      ])
  }

  @Test
  func createArgsCopyBothIncludesVerbose() {
    let spec = CreateWorktreeSpec(
      repoRoot: URL(fileURLWithPath: "/repo"),
      baseDirectory: URL(fileURLWithPath: "/base"),
      name: "feature",
      baseRef: "main",
      fetchOrigin: false,
      copyIgnored: true,
      copyUntracked: true
    )
    #expect(
      GitWorktreeClient.makeCreateArguments(for: spec) == [
        "--base-dir", "/base",
        "sw",
        "--copy-ignored",
        "--copy-untracked",
        "--from", "main",
        "--verbose",
        "feature",
      ])
  }

  @Test
  func createArgsEmptyBaseRefIsSkipped() {
    let spec = CreateWorktreeSpec(
      repoRoot: URL(fileURLWithPath: "/repo"),
      baseDirectory: URL(fileURLWithPath: "/base"),
      name: "feature",
      baseRef: "",
      fetchOrigin: false,
      copyIgnored: false,
      copyUntracked: false
    )
    #expect(
      GitWorktreeClient.makeCreateArguments(for: spec) == [
        "--base-dir", "/base",
        "sw",
        "feature",
      ])
  }

  // MARK: - wt ls --json decode

  @Test
  func lsJSONDecode() throws {
    let json = #"""
      [
        {"branch":"main","path":"/tmp/repo","head":"abc123","is_bare":false},
        {"branch":"feature","path":"/tmp/feature","head":"def456","is_bare":false},
        {"branch":"","path":"/tmp/bare","head":"","is_bare":true}
      ]
      """#
    let data = Data(json.utf8)
    let entries = try JSONDecoder().decode([GitWtEntry].self, from: data)
    #expect(entries.count == 3)
    #expect(entries[0].branch == "main")
    #expect(entries[0].path == "/tmp/repo")
    #expect(entries[0].isBare == false)
    #expect(entries[2].isBare == true)
  }

  // MARK: - mapGitStderr

  @Test
  func stderrMapsBranchExists() {
    let err = GitWorktreeClient.mapGitStderr(
      command: "git worktree add -b feature /tmp/feature",
      stderr: "fatal: A branch named 'feature' already exists"
    )
    #expect(err == .branchExists("feature"))
  }

  @Test
  func stderrMapsBranchExistsUppercase() {
    // Locales or future git releases may emit uppercased stderr. The
    // pattern is case-insensitive; captured branch-name keeps its
    // original casing for faithful UI display.
    let err = GitWorktreeClient.mapGitStderr(
      command: "git worktree add -b X /tmp/X",
      stderr: "FATAL: A BRANCH NAMED 'X' ALREADY EXISTS"
    )
    #expect(err == .branchExists("X"))
  }

  @Test
  func stderrMapsBranchExistsTitleCase() {
    let err = GitWorktreeClient.mapGitStderr(
      command: "git worktree add -b Feat /tmp/Feat",
      stderr: "Fatal: A Branch Named 'Feat' Already Exists"
    )
    #expect(err == .branchExists("Feat"))
  }

  @Test
  func stderrMapsInvalidBranchName() {
    let err = GitWorktreeClient.mapGitStderr(
      command: "git worktree add",
      stderr: "fatal: 'bad name' is not a valid branch name"
    )
    #expect(err == .invalidBranchName("bad name"))
  }

  @Test
  func stderrMapsInvalidBranchNameMixedCase() {
    let err = GitWorktreeClient.mapGitStderr(
      command: "git worktree add",
      stderr: "Fatal: 'Bad Name' Is Not A Valid Branch Name"
    )
    #expect(err == .invalidBranchName("Bad Name"))
  }

  @Test
  func stderrMapsRefNotFound() {
    let err = GitWorktreeClient.mapGitStderr(
      command: "git worktree add",
      stderr: "fatal: ambiguous argument 'missing': unknown revision or path not in the working tree."
    )
    if case .refNotFound = err {
      // expected
    } else {
      Issue.record("expected .refNotFound, got \(err)")
    }
  }

  @Test
  func stderrMapsWorktreeLocked() {
    let err = GitWorktreeClient.mapGitStderr(
      command: "git worktree remove /tmp/feature",
      stderr: "fatal: '/tmp/feature' is locked"
    )
    if case .worktreeLocked = err {
      // expected
    } else {
      Issue.record("expected .worktreeLocked, got \(err)")
    }
  }

  @Test
  func stderrMapsUncommittedChanges() {
    let err = GitWorktreeClient.mapGitStderr(
      command: "git worktree remove /tmp/feature",
      stderr: "fatal: '/tmp/feature' contains modified or untracked files, use --force to delete it"
    )
    if case .uncommittedChanges(let files) = err {
      #expect(files.isEmpty)  // caller enriches via porcelain parse
    } else {
      Issue.record("expected .uncommittedChanges, got \(err)")
    }
  }

  @Test
  func stderrFallsBackToCommandFailed() {
    let err = GitWorktreeClient.mapGitStderr(
      command: "git worktree remove",
      stderr: "some unrecognized error"
    )
    #expect(err == .commandFailed(command: "git worktree remove", stderr: "some unrecognized error"))
  }

  // MARK: - stderrIndicatesAlreadyRemoved

  @Test
  func alreadyRemovedDetectsNotAWorkingTree() {
    // Reproduces the orphaned-node case: the catalog path no longer
    // maps to a registered worktree, so Remove must be idempotent.
    #expect(
      GitWorktreeClient.stderrIndicatesAlreadyRemoved(
        "fatal: '/Users/u/.prowl/repos/x/feat/gone' is not a working tree"
      )
    )
  }

  @Test
  func alreadyRemovedRejectsRealFailures() {
    #expect(!GitWorktreeClient.stderrIndicatesAlreadyRemoved("fatal: '/tmp/x' is locked"))
    #expect(
      !GitWorktreeClient.stderrIndicatesAlreadyRemoved(
        "fatal: '/tmp/x' contains modified or untracked files, use --force to delete it"
      )
    )
    #expect(!GitWorktreeClient.stderrIndicatesAlreadyRemoved("some unrecognized error"))
  }

  // MARK: - parsePorcelainPaths

  @Test
  func porcelainParsesModifiedAndUntracked() {
    let output = " M path/to/a.swift\n?? path/to/b.swift\n"
    #expect(GitWorktreeClient.parsePorcelainPaths(output) == ["path/to/a.swift", "path/to/b.swift"])
  }

  // MARK: - pickNewWorktreePath

  private func entry(path: String, branch: String = "x") -> GitWtEntry {
    GitWtEntry(branch: branch, path: path, head: "abc123", isBare: false)
  }

  @Test
  func pickNewWorktreePathCleanDiffReturnsNewPath() {
    let pre = [entry(path: "/tmp/repo", branch: "main")]
    let post = [
      entry(path: "/tmp/repo", branch: "main"),
      entry(path: "/tmp/repo/.worktrees/feature", branch: "feature"),
    ]
    let picked = GitWorktreeClient.pickNewWorktreePath(
      preEntries: pre, postEntries: post, fallbackStdoutLast: ""
    )
    #expect(picked?.path == "/tmp/repo/.worktrees/feature")
  }

  @Test
  func pickNewWorktreePathNoDiffReturnsNil() {
    let entries = [entry(path: "/tmp/repo", branch: "main")]
    let picked = GitWorktreeClient.pickNewWorktreePath(
      preEntries: entries,
      postEntries: entries,
      fallbackStdoutLast: "/tmp/something"
    )
    #expect(picked == nil)
  }

  @Test
  func pickNewWorktreePathMultipleNewDisambiguatesByFallback() {
    let pre = [entry(path: "/tmp/repo", branch: "main")]
    let post = [
      entry(path: "/tmp/repo", branch: "main"),
      entry(path: "/tmp/repo/.worktrees/a", branch: "a"),
      entry(path: "/tmp/repo/.worktrees/b", branch: "b"),
    ]
    let picked = GitWorktreeClient.pickNewWorktreePath(
      preEntries: pre,
      postEntries: post,
      fallbackStdoutLast: "/tmp/repo/.worktrees/b"
    )
    #expect(picked?.path == "/tmp/repo/.worktrees/b")
  }

  @Test
  func pickNewWorktreePathMultipleNewNoFallbackMatchReturnsFirst() {
    let pre = [entry(path: "/tmp/repo", branch: "main")]
    let post = [
      entry(path: "/tmp/repo", branch: "main"),
      entry(path: "/tmp/repo/.worktrees/a", branch: "a"),
      entry(path: "/tmp/repo/.worktrees/b", branch: "b"),
    ]
    // Fallback doesn't match any new entry — pickNewWorktreePath
    // returns the first new one so the caller isn't blocked.
    let picked = GitWorktreeClient.pickNewWorktreePath(
      preEntries: pre,
      postEntries: post,
      fallbackStdoutLast: "/unrelated/path"
    )
    #expect(picked?.path == "/tmp/repo/.worktrees/a")
  }

  @Test
  func pickNewWorktreePathCanonicalizesTrailingSlash() {
    // wt ls may emit paths with a trailing slash where the stdoutLast
    // doesn't (or vice versa); standardizedFileURL handles that.
    let pre = [entry(path: "/tmp/repo", branch: "main")]
    let post = [
      entry(path: "/tmp/repo", branch: "main"),
      entry(path: "/tmp/repo/.worktrees/feat/", branch: "feat"),
    ]
    let picked = GitWorktreeClient.pickNewWorktreePath(
      preEntries: pre,
      postEntries: post,
      fallbackStdoutLast: "/tmp/repo/.worktrees/feat"
    )
    // standardizedFileURL strips the trailing slash from a directory
    // path at comparison time; the returned URL should be the
    // canonical form.
    #expect(picked?.path == "/tmp/repo/.worktrees/feat")
  }

  @Test
  func porcelainIgnoresBlankLines() {
    let output = "\n M a\n\n\n ? b\n"
    #expect(GitWorktreeClient.parsePorcelainPaths(output) == ["a", "b"])
  }
}
