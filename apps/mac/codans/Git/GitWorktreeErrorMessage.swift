import Foundation

/// Maps `GitWorktreeError` to a single-line, human-friendly string for
/// banners, sidebar pending-row error captions, and toasts. Reads better
/// than `localizedDescription` (which is often raw stderr) and centralizes
/// the wording so the Create / Archived / Pending paths agree.
nonisolated func humanReadable(_ error: GitWorktreeError) -> String {
  switch error {
  case .branchExists(let name):
    return "Branch \"\(name)\" already exists."
  case .invalidBranchName(let name):
    return "Branch name \"\(name)\" is not valid."
  case .refNotFound(let ref):
    return "Base ref not found: \(ref)"
  case .fetchFailed(let detail):
    return "git fetch origin failed: \(detail)"
  case .executableMissing:
    return "The bundled wt helper is missing. Reinstall codans."
  case .uncommittedChanges:
    return "The worktree has uncommitted changes."
  case .worktreeLocked(let detail):
    return "Worktree is locked: \(detail)"
  case .commandFailed(let command, let stderr):
    return "\(command): \(stderr)"
  }
}
