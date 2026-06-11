import Foundation

/// Public namespace for the in-app Git module. Types defined inside `codans/Git/` are
/// accessed via this namespace from the rest of the app (e.g. `Git.makeService()`).
public nonisolated enum Git {
  /// Returns a live `GitService` backed by `Foundation.Process`. `gitExecutable` defaults to
  /// `/usr/bin/env` with `git` as argv[0], which resolves through `$PATH` rather than pinning
  /// to a specific install.
  public static func makeService(gitExecutable: URL? = nil) -> any GitService {
    if let url = gitExecutable {
      return LiveGitService(gitExecutable: url)
    }
    return LiveGitService()
  }
}
