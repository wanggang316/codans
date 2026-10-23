import Foundation

/// How a workspace member is checked out from its source repository.
public nonisolated enum WorkspaceCheckout: Equatable, Sendable {
  /// `git worktree add -b <branch> <path> [<baseRef>]`. A nil base ref lets
  /// the caller substitute the repository's default remote branch, falling
  /// back to git's own default (HEAD).
  case newBranch(branch: String, baseRef: String?)
  /// `git worktree add <path> <branch>` on a branch that already exists
  /// locally.
  case existingBranch(String)
  /// Check out a remote-tracking ref such as `origin/feature` as the local
  /// branch `branch`. When no local branch of that name exists this is
  /// `git worktree add --track -b <branch> <path> <remoteRef>`. When one does
  /// exist the caller decides: `resetLocal == false` checks the local branch
  /// out as it is (the remote ref only names it); `resetLocal == true` runs
  /// `--track -B`, which points the local branch at the remote tip and
  /// discards local-only commits. The reset is never implied.
  case remoteTrackingRef(remoteRef: String, branch: String, resetLocal: Bool)

  public var branch: String {
    switch self {
    case .newBranch(let branch, _): return branch
    case .existingBranch(let branch): return branch
    case .remoteTrackingRef(_, let branch, _): return branch
    }
  }

  /// The ref the checkout starts from: the base of a new branch, or the
  /// remote-tracking ref. Nil for an existing local branch.
  public var baseRef: String? {
    switch self {
    case .newBranch(_, let baseRef): return baseRef
    case .existingBranch: return nil
    case .remoteTrackingRef(let remoteRef, _, _): return remoteRef
    }
  }

  public var manifestMode: WorkspaceManifest.CheckoutMode {
    switch self {
    case .newBranch: return .newBranch
    case .existingBranch: return .existingBranch
    case .remoteTrackingRef: return .remoteTrackingRef
    }
  }

  /// `<remote>/<branch>` split at the first slash; nil when the ref names
  /// no remote. `origin/feature/x` → (`origin`, `feature/x`).
  public static func splitRemoteRef(_ ref: String) -> (remote: String, branch: String)? {
    guard let slash = ref.firstIndex(of: "/") else { return nil }
    let remote = String(ref[..<slash])
    let branch = String(ref[ref.index(after: slash)...])
    guard !remote.isEmpty, !branch.isEmpty else { return nil }
    return (remote, branch)
  }
}
