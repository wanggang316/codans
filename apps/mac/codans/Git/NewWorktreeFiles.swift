import CodansCore
import Foundation

/// The files of a main checkout that a new worktree will not have. `wt`
/// creates the worktree from the tracked files and copies the ignored
/// (`--copy-ignored`) and the untracked (`--copy-untracked`) files only when
/// asked. The lists below use the same `git ls-files` commands as `wt`.
nonisolated enum NewWorktreeFiles {
  /// `nil` when both options copy: the worktree gets every file.
  static func exclusion(
    repoRoot: URL, copyIgnored: Bool, copyUntracked: Bool
  ) async -> ProjectFileExclusion? {
    if copyIgnored && copyUntracked { return nil }
    var paths = Set<String>()
    if !copyIgnored {
      guard let ignored = await list(["--ignored", "--directory"], repoRoot: repoRoot) else {
        return ProjectFileExclusion(root: repoRoot, paths: nil)
      }
      paths.formUnion(ignored)
    }
    if !copyUntracked {
      guard let untracked = await list([], repoRoot: repoRoot) else {
        return ProjectFileExclusion(root: repoRoot, paths: nil)
      }
      paths.formUnion(untracked)
    }
    return ProjectFileExclusion(root: repoRoot, paths: paths)
  }

  /// Untracked paths, or ignored ones with `--ignored`. With `--directory`,
  /// a directory with no tracked file is one `dir/` entry. The untracked
  /// list must not use it: git also lists a directory that holds ignored
  /// files that way, and `wt` copies those with `--copy-ignored`. `nil` when
  /// git fails or the list is cut off.
  private static func list(_ extra: [String], repoRoot: URL) async -> Set<String>? {
    let arguments =
      ["-C", repoRoot.path(percentEncoded: false), "ls-files", "--others"] + extra
      + ["--exclude-standard", "-z"]
    let outcome = await GitWorktreeShell.run(
      executable: GitWorktreeShell.gitURL, arguments: arguments, cwd: repoRoot)
    guard case .exited(0, let stdout, _, false) = outcome else { return nil }
    return parse(stdout)
  }

  static func parse(_ output: Data) -> Set<String> {
    Set(
      GitWorktreeShell.decodeUTF8(output).split(separator: "\0").map(String.init)
        .filter { !$0.hasPrefix(".git/") })
  }
}
