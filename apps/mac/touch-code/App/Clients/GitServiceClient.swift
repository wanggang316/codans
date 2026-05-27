import ComposableArchitecture
import Foundation
import TouchCodeCore

/// TCA dependency-injection bridge over the `GitService` protocol from
/// `touch-code/Git/`. Each closure mirrors one protocol method. Mirrors
/// `HierarchyClient` / `TerminalClient` in shape so features use a
/// consistent pattern.
///
/// Not `@MainActor`: `GitService` is nonisolated and conforms to `Sendable`.
/// Closures are `@Sendable` async — safe to call from any reducer effect.
nonisolated struct GitServiceClient: Sendable {
  /// `(repoURL, cursor) -> LogPage`.
  var log: @Sendable (URL, LogPage.Cursor) async throws -> LogPage
  /// `(repoURL, ignoreWhitespace) -> UnifiedDiff`. `ignoreWhitespace=true` passes `-w`.
  var workingTreeDiff: @Sendable (URL, Bool) async throws -> UnifiedDiff
  var stagedDiff: @Sendable (URL, Bool) async throws -> UnifiedDiff
  /// `(repoURL, sha, ignoreWhitespace) -> UnifiedDiff`.
  var commitDiff: @Sendable (URL, String, Bool) async throws -> UnifiedDiff
  /// `(repoURL) -> WorkingTreeStatus`. Used by the sidebar's dirty-indicator to decide
  /// whether a Worktree row carries a pending-work dot; `GitService.status(at:)` had been
  /// a protocol-only method waiting for this UI surface (see 0005 M3 review item 2).
  var status: @Sendable (URL) async throws -> WorkingTreeStatus
  /// `(repoURL) -> RemoteInfo`. Parses `git remote get-url origin` into host/owner/repo
  /// for the GitHub integration's batched PR fetcher. Throws `GitError.malformedRemoteURL`
  /// on an unrecognised remote shape.
  var remoteInfo: @Sendable (URL) async throws -> RemoteInfo
  /// `(worktreePath) -> [ChangedFile]`. Drives the Diff inspector. Closure takes a
  /// String path (rather than URL) because the reducer caches the worktree path as
  /// String and the call site stays one conversion lighter.
  var diffNumstat: @Sendable (String) async throws -> [ChangedFile]
  /// `(path, worktreePath) -> oldContents?`. Reads `<path>` at HEAD via `git show`.
  /// Returns `nil` for paths that don't yet exist at HEAD (newly-added files).
  var showFileAtHEAD: @Sendable (String, String) async throws -> String?
  /// `(worktreePath) -> LocalDiffStats?`. Sums insertions/deletions for the
  /// worktree's uncommitted edits (`git diff HEAD --shortstat`). Nil only on
  /// git failure; a clean tree yields `LocalDiffStats(0, 0)`.
  var localDiffStats: @Sendable (URL) async throws -> LocalDiffStats?
  /// `(repoURL) -> currentBranch?`. `git symbolic-ref --short HEAD`. Returns nil on
  /// detached HEAD; throws on other failures via the standard `GitError` cases.
  var currentBranch: @Sendable (URL) async throws -> String?
  /// `(repoURL) -> BranchInventory`. One-shot `git for-each-ref` covering refs/heads
  /// + refs/remotes, parsed and rendered ready (current pinned to local position 0,
  /// `<remote>/HEAD` filtered, sorted ascending by short name).
  var listAllBranches: @Sendable (URL) async throws -> BranchInventory
  /// `(target, repoURL) -> Void`. `git switch <name>` for `.local`, `git switch --track
  /// <origin/x>` for `.remoteTracking`. Dirty-tree / conflict failures surface as
  /// `GitError.exec(code, stderr)` with stderr verbatim; the popover reducer's banner
  /// extracts the first line.
  var switchBranch: @Sendable (BranchSwitchTarget, URL) async throws -> Void
  /// `(newName, repoURL) -> Void`. `git branch -m <newName>`.
  var renameCurrentBranch: @Sendable (String, URL) async throws -> Void
}

extension GitServiceClient {
  /// Constructs a client that forwards to a concrete `GitService`.
  static func live(service: any GitService = Git.makeService()) -> GitServiceClient {
    GitServiceClient(
      log: { url, cursor in try await service.log(at: url, page: cursor) },
      workingTreeDiff: { url, ignoreWhitespace in
        try await service.workingTreeDiff(at: url, ignoreWhitespace: ignoreWhitespace)
      },
      stagedDiff: { url, ignoreWhitespace in
        try await service.stagedDiff(at: url, ignoreWhitespace: ignoreWhitespace)
      },
      commitDiff: { url, sha, ignoreWhitespace in
        try await service.commitDiff(at: url, sha: sha, ignoreWhitespace: ignoreWhitespace)
      },
      status: { url in try await service.status(at: url) },
      remoteInfo: { url in try await service.remoteInfo(at: url) },
      diffNumstat: { path in
        try await service.diffNumstat(at: URL(fileURLWithPath: path))
      },
      showFileAtHEAD: { path, worktreePath in
        try await service.showFileAtHEAD(path, at: URL(fileURLWithPath: worktreePath))
      },
      localDiffStats: { url in try await service.localDiffStats(at: url) },
      currentBranch: { url in try await service.currentBranch(at: url) },
      listAllBranches: { url in try await service.listAllBranches(at: url) },
      switchBranch: { target, url in try await service.switchBranch(to: target, at: url) },
      renameCurrentBranch: { newName, url in
        try await service.renameCurrentBranch(to: newName, at: url)
      }
    )
  }
}

extension GitServiceClient: DependencyKey {
  static let liveValue: GitServiceClient = .live()

  static let testValue: GitServiceClient = GitServiceClient(
    log: unimplemented(
      "GitServiceClient.log",
      placeholder: LogPage(cursor: .init(offset: 0, limit: 0), commits: [], hasMore: false)
    ),
    workingTreeDiff: unimplemented(
      "GitServiceClient.workingTreeDiff",
      placeholder: UnifiedDiff(scope: .working, files: [])
    ),
    stagedDiff: unimplemented(
      "GitServiceClient.stagedDiff",
      placeholder: UnifiedDiff(scope: .staged, files: [])
    ),
    commitDiff: unimplemented(
      "GitServiceClient.commitDiff",
      placeholder: UnifiedDiff(scope: .commit(sha: ""), files: [])
    ),
    status: unimplemented(
      "GitServiceClient.status",
      placeholder: WorkingTreeStatus(entries: [])
    ),
    remoteInfo: unimplemented(
      "GitServiceClient.remoteInfo",
      placeholder: RemoteInfo(host: "github.com", owner: "example", repo: "example")
    ),
    diffNumstat: unimplemented(
      "GitServiceClient.diffNumstat",
      placeholder: []
    ),
    showFileAtHEAD: unimplemented(
      "GitServiceClient.showFileAtHEAD",
      placeholder: nil
    ),
    localDiffStats: unimplemented(
      "GitServiceClient.localDiffStats",
      placeholder: nil
    ),
    currentBranch: unimplemented(
      "GitServiceClient.currentBranch",
      placeholder: nil
    ),
    listAllBranches: unimplemented(
      "GitServiceClient.listAllBranches",
      placeholder: BranchInventory(current: nil, local: [], remote: [])
    ),
    switchBranch: unimplemented(
      "GitServiceClient.switchBranch"
    ),
    renameCurrentBranch: unimplemented(
      "GitServiceClient.renameCurrentBranch"
    )
  )
}

extension DependencyValues {
  var gitService: GitServiceClient {
    get { self[GitServiceClient.self] }
    set { self[GitServiceClient.self] = newValue }
  }
}
