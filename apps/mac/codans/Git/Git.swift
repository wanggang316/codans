import CodansCore
import Foundation

/// Public namespace for the in-app Git module. Types defined inside `codans/Git/` are
/// accessed via this namespace from the rest of the app (e.g. `Git.makeService()`).
public nonisolated enum Git {
  /// Returns a live `GitService` backed by `Foundation.Process`. `gitExecutable` defaults to
  /// `/usr/bin/env` with `git` as argv[0], which resolves through `$PATH` rather than pinning
  /// to a specific install.
  ///
  /// `remoteHostResolver` is the Server-project transport seam: when it maps a
  /// repository path to a `RemoteHost`, that invocation runs `git` over SSH on
  /// the host instead of locally. The default always-`nil` resolver keeps the
  /// service purely local.
  public static func makeService(
    gitExecutable: URL? = nil,
    remoteHostResolver: @escaping @Sendable (URL) async -> RemoteHost? = { _ in nil }
  ) -> any GitService {
    if let url = gitExecutable {
      return LiveGitService(gitExecutable: url, resolveRemoteHost: remoteHostResolver)
    }
    return LiveGitService(resolveRemoteHost: remoteHostResolver)
  }
}
