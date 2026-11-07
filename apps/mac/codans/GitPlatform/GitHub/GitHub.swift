import CodansCore
import Foundation

/// Namespace for the GitHub implementation of the `GitPlatform` protocol.
///
/// The implementation wraps the `gh` CLI. It is the only code that knows GitHub wire
/// values (GraphQL enums, `gh` JSON shapes, `gh` flags); it returns the provider-neutral
/// model from `CodansCore`.
///
/// Dependency rules (folder-level, enforced by review):
/// - May import `Foundation`, `CodansCore`, `codans/Process/` (`CommandRunner`), and the
///   shared `codans/GitPlatform/` types.
/// - Must not import `codans/Git/`, `codans/Runtime/`, `codans/Hooks/`, SwiftUI, or TCA.
nonisolated enum GitHub {
  /// `[HOST/]OWNER/REPO` form that `gh --repo` accepts. GitHub repositories have exactly
  /// two path segments; a remote with more keeps the first two, as `gh` would.
  static func repoArgument(_ repository: GitPlatformRepository) -> String {
    let segments = repository.pathSegments.prefix(2)
    return ([repository.host] + segments).joined(separator: "/")
  }

  /// Owner and name of a GitHub repository, from its path.
  static func ownerAndName(_ repository: GitPlatformRepository) -> (owner: String, name: String) {
    let segments = repository.pathSegments
    return (segments.first ?? "", segments.dropFirst().first ?? "")
  }
}
