import Foundation
import CodansCore

/// Argv builder for the Git CLI. Each static method produces the arguments passed to `git` —
/// never to a shell. `gitExecutable` itself is argv[0] on the Process side; these arrays
/// supply argv[1...].
///
/// Every command that emits path bytes includes `-c core.quotePath=false` so non-ASCII paths
/// arrive as UTF-8 rather than octal escapes. Read-only operations only: `log`, `diff`,
/// `show`, `status`, `rev-parse`.
///
/// `nonisolated` — pure argv construction with no actor concerns.
nonisolated enum GitCommand {
  /// `git log --pretty=format:… --no-color -z --date=iso-strict -n <limit> [--skip <offset>]`
  static func log(limit: Int, skip: Int) -> [String] {
    precondition(limit > 0, "log limit must be positive")
    precondition(skip >= 0, "log skip must be non-negative")
    var args: [String] = [
      "-c", "core.quotePath=false",
      "log",
      "--pretty=format:%H%x00%an%x00%ae%x00%aI%x00%s%x00%P",
      "--no-color",
      "-z",
      "--date=iso-strict",
      "-n",
      String(limit),
    ]
    if skip > 0 {
      args.append(contentsOf: ["--skip", String(skip)])
    }
    return args
  }

  enum DiffKind {
    case workingTree
    case staged
    case commit(sha: String)
  }

  /// `git diff` / `git diff --cached` / `git show <sha>` argv. For `.commit`, the SHA is
  /// followed by `--` to close the SHA/path ambiguity per git's documented argv grammar.
  ///
  /// Correctness note: every flag (`-w`, `-M`, `-C`, `-U3`, `--cached`) must precede the
  /// `--` separator. Tokens after `--` are interpreted as pathspec — a bug in the first
  /// M4a cut of this file placed `-w` after `--` for `.commit`, silently creating a path
  /// filter named `-w` instead of enabling ignore-whitespace. See 0005 DEC-19.
  static func diff(kind: DiffKind, ignoreWhitespace: Bool = false) -> [String] {
    var args: [String] = ["-c", "core.quotePath=false"]
    let whitespaceFlags: [String] = ignoreWhitespace ? ["-w"] : []

    switch kind {
    case .workingTree:
      args += ["diff", "--no-color", "--no-ext-diff", "-M", "-C", "-U3"]
      args += whitespaceFlags
    case .staged:
      args += ["diff", "--no-color", "--no-ext-diff", "-M", "-C", "-U3", "--cached"]
      args += whitespaceFlags
    case .commit(let sha):
      // `git show` emits the unified-diff stream; `--format=` drops the commit header the
      // caller already has via log. `-w` (when set) lands BEFORE the SHA + `--` trailer —
      // git treats anything after `--` as pathspec.
      args += ["show", "--no-color", "--no-ext-diff", "-M", "-C", "-U3", "--format="]
      args += whitespaceFlags
      args += [sha, "--"]
    }
    return args
  }

  static func status() -> [String] {
    [
      "-c", "core.quotePath=false",
      "status", "--porcelain=v1", "-z", "--untracked-files=all",
    ]
  }

  /// `git rev-parse --is-inside-work-tree`. Exit 0 + `"true"` on stdout = inside a work tree;
  /// any non-zero exit = not a repo. Used by `LiveGitService.ensureIsRepo`.
  static func revParseIsInsideWorkTree() -> [String] {
    ["rev-parse", "--is-inside-work-tree"]
  }

  /// `git rev-parse --show-toplevel`. Reserved for a future worktree-root discovery helper;
  /// not called from M2's service paths but documented as available.
  static func revParseShowToplevel() -> [String] {
    ["rev-parse", "--show-toplevel"]
  }

  /// `git remote get-url <remote>`. Emits the raw remote URL — SCP-style (`git@host:o/r`),
  /// HTTPS, or `ssh://`. Parsed via `RemoteInfo.parse` at the service boundary. Defaults to
  /// the `origin` remote since the GitHub integration does not support multi-remote setups.
  static func remoteGetUrl(remote: String = "origin") -> [String] {
    ["remote", "get-url", remote]
  }

  /// `git symbolic-ref --short HEAD`. Exit 0 + branch on stdout when HEAD points at a ref;
  /// exit 1 (no stdout) when HEAD is detached. Caller maps the exit 1 case to "detached".
  static func symbolicRefShortHead() -> [String] {
    ["symbolic-ref", "--short", "HEAD"]
  }

  /// `git for-each-ref … refs/heads refs/remotes` formatted for parser ingestion.
  /// Fields per record (TAB-separated): full refname, short refname, upstream short name,
  /// HEAD marker (`*` for current, space otherwise). Records are newline-separated.
  /// Branch names cannot contain TAB or LF per git ref-naming rules, so the chosen
  /// separators are unambiguous.
  static func forEachRefBranches() -> [String] {
    [
      "-c", "core.quotePath=false",
      "for-each-ref",
      "--format=%(refname)%09%(refname:short)%09%(upstream:short)%09%(HEAD)",
      "refs/heads", "refs/remotes",
    ]
  }

  /// `git switch <name>` for `.local`, `git switch --track <origin/x>` for `.remoteTracking`.
  /// No `-C` / `--create`; switching to a non-existent local branch must fail with git's
  /// native error rather than silently create. Returns argv only — caller wraps with the
  /// shared subprocess runner.
  static func switchBranch(target: BranchSwitchTarget) -> [String] {
    switch target {
    case .local(let name):
      return ["switch", name]
    case .remoteTracking(let shortName):
      return ["switch", "--track", shortName]
    }
  }

  /// `git branch -m <oldName> <newName>` — rename any branch. Works on the
  /// current branch (git's "-m" handles HEAD-ref rewrite atomically) and on
  /// non-current local branches. Errors (duplicate target, invalid name,
  /// branch is checked out elsewhere on stale git) surface as
  /// `GitError.exec` with stderr preserved.
  static func branchRename(from oldName: String, to newName: String) -> [String] {
    precondition(!oldName.isEmpty, "branch rename source must be non-empty")
    precondition(!newName.isEmpty, "branch rename target must be non-empty")
    return ["branch", "-m", oldName, newName]
  }

  /// `git switch -c <newName> <baseName>` — create `<newName>` from
  /// `<baseName>` and switch HEAD to it in one atomic step. Equivalent to
  /// `git checkout -b <newName> <baseName>` but uses the modern verb.
  /// `<baseName>` may be a local branch ("main"), a remote tracking ref
  /// ("origin/feat/x"), or any committish.
  static func switchCreate(name: String, from baseName: String) -> [String] {
    precondition(!name.isEmpty, "new-branch name must be non-empty")
    precondition(!baseName.isEmpty, "new-branch base must be non-empty")
    return ["switch", "-c", name, baseName]
  }

  /// `git log -1 --format=%B <sha>` — fetches the FULL commit message
  /// (subject + body, raw multi-line). The `%B` format key is the
  /// canonical "body including subject" specifier. Used by the popover's
  /// lazy fetch when a row is first hovered.
  static func showCommitMessage(sha: String) -> [String] {
    precondition(!sha.isEmpty, "sha must be non-empty")
    return ["log", "-1", "--format=%B", sha]
  }
}
