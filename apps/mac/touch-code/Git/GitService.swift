import Foundation
import TouchCodeCore

/// Read-only Git service. Invoked by `GitViewerFeature` (M3) and, in future, by the `git.*` IPC
/// namespace. All operations are pure with respect to the file system — they never write.
///
/// `nonisolated` so conformers (including `LiveGitService`) can freely be `Sendable` without
/// fighting the app target's `@MainActor` default.
public nonisolated protocol GitService: Sendable {
  /// Commit log for the repository at `path`, paginated by `page`.
  func log(at path: URL, page: LogPage.Cursor) async throws -> LogPage

  /// `git diff` — working tree vs. index. `ignoreWhitespace=true` passes `-w`.
  func workingTreeDiff(at path: URL, ignoreWhitespace: Bool) async throws -> UnifiedDiff

  /// `git diff --cached` — index vs. HEAD. `ignoreWhitespace=true` passes `-w`.
  func stagedDiff(at path: URL, ignoreWhitespace: Bool) async throws -> UnifiedDiff

  /// `git show <sha>` rendered as a unified diff. `ignoreWhitespace=true` passes `-w`.
  func commitDiff(at path: URL, sha: String, ignoreWhitespace: Bool) async throws -> UnifiedDiff

  /// `git status --porcelain=v1 -z`.
  func status(at path: URL) async throws -> WorkingTreeStatus

  /// `git remote get-url origin` parsed into host / owner / repo. Used by the GitHub
  /// integration's batched PR fetcher to target the right `gh api graphql --hostname` host
  /// and `(owner, repo)` variables. Throws `GitError.malformedRemoteURL` when the remote
  /// URL shape is not recognised.
  func remoteInfo(at path: URL) async throws -> RemoteInfo

  /// `git diff --numstat -z` + `git diff --name-status -z` joined into the per-row
  /// model the Diff inspector consumes. The two commands are combined here (rather
  /// than in the feature) so the parser stays in the git-domain module and the
  /// reducer remains a thin coordinator.
  func diffNumstat(at worktreePath: URL) async throws -> [ChangedFile]

  /// `git show HEAD:<path>` — UTF-8 contents of `path` at HEAD. Returns `nil` for
  /// paths that don't exist at HEAD (newly-added files). All other errors throw
  /// the standard `GitError` cases.
  func showFileAtHEAD(_ path: String, at worktreePath: URL) async throws -> String?

  /// `git diff HEAD --shortstat` — summed insertions / deletions for the
  /// worktree's uncommitted edits. Returns `nil` only when the call itself
  /// fails (not a repo, transient git error). A clean tree returns a stats
  /// value with both counts at zero, not nil.
  func localDiffStats(at worktreePath: URL) async throws -> LocalDiffStats?

  /// `git symbolic-ref --short HEAD`. Returns the current branch's short name when HEAD
  /// points at a ref; returns `nil` when HEAD is detached. Other failures (not-a-repo,
  /// git missing, timeout) throw via the standard `GitError` cases.
  func currentBranch(at path: URL) async throws -> String?

  /// `git for-each-ref refs/heads refs/remotes` parsed through
  /// `GitOutputParser.parseBranchInventory`. Returns a render-ready inventory:
  /// current is server-side resolved, lists are sorted, `<remote>/HEAD` is filtered,
  /// and the current branch (if local) is pinned to position 0.
  func listAllBranches(at path: URL) async throws -> BranchInventory

  /// `git switch <name>` for `.local`, `git switch --track <origin/x>` for
  /// `.remoteTracking`. Dirty-tree / conflict failures surface as
  /// `GitError.exec(code, stderr)` with stderr preserved verbatim — the caller
  /// (BranchSwitcherFeature, T6) extracts the first line for the inline error
  /// banner. No pre-check; rely on git's native enforcement.
  func switchBranch(to target: BranchSwitchTarget, at path: URL) async throws

  /// `git branch -m <oldName> <newName>` — rename any local branch. The
  /// current branch is allowed (git handles HEAD-ref rewrite atomically);
  /// non-current local branches are also fine. Renaming a remote-tracking
  /// ref is NOT supported by git and surfaces as `GitError.exec`. After a
  /// current-branch rename the worktree's HEAD ref text becomes
  /// `ref: refs/heads/<newName>`, which the existing `WorktreeHeadWatcher`
  /// picks up to refresh the catalog + clear the inventory cache.
  func renameBranch(from oldName: String, to newName: String, at path: URL) async throws

  /// `git switch -c <newName> <baseName>` — create a new local branch from
  /// the given base and switch HEAD to it. The base may be local or a
  /// remote tracking ref. After success, the worktree's HEAD ref points at
  /// `<newName>`; the existing `WorktreeHeadWatcher` picks up the change.
  func createAndSwitchBranch(name newName: String, from baseName: String, at path: URL) async throws

  /// `git log -1 --format=%B <sha>`. Returns the raw multi-line message
  /// (subject on first line, then a blank line, then body). Empty body
  /// is rendered as just the subject. Failure modes (unknown sha, repo
  /// mismatch) propagate as `GitError.exec`.
  func commitMessage(sha: String, at path: URL) async throws -> String
}

extension GitService {
  /// Convenience overloads: `ignoreWhitespace` defaults to false. Keeps old call sites
  /// (integration tests, future IPC bridge) readable.
  public func workingTreeDiff(at path: URL) async throws -> UnifiedDiff {
    try await workingTreeDiff(at: path, ignoreWhitespace: false)
  }
  public func stagedDiff(at path: URL) async throws -> UnifiedDiff {
    try await stagedDiff(at: path, ignoreWhitespace: false)
  }
  public func commitDiff(at path: URL, sha: String) async throws -> UnifiedDiff {
    try await commitDiff(at: path, sha: sha, ignoreWhitespace: false)
  }
}
