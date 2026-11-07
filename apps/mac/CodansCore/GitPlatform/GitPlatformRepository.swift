import Foundation

/// A repository on a Git Platform: its kind, its host, and its full path. The path keeps
/// every segment (`owner/repo`, or `group/sub/repo` on GitLab), so two repositories with
/// the same name in different groups stay distinct. See ADR 0004 item 12.
public nonisolated struct GitPlatformRepository: Equatable, Hashable, Codable, Sendable {
  public var kind: GitPlatformKind
  public var host: String
  public var path: String

  public init(kind: GitPlatformKind, host: String, path: String) {
    self.kind = kind
    self.host = host
    self.path = path
  }

  /// Path segments in order, for example `["group", "sub", "repo"]`.
  public var pathSegments: [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  }
}

/// Identifies one Pull Request: the repository and the number the Git Platform gives it
/// inside that repository. Write actions take this reference, not a working directory,
/// so the subprocess does not resolve the repository from its `cwd`.
public nonisolated struct PullRequestReference: Equatable, Hashable, Sendable {
  public var repository: GitPlatformRepository
  public var number: Int

  public init(repository: GitPlatformRepository, number: Int) {
    self.repository = repository
    self.number = number
  }
}
