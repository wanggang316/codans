import CodansCore
import Foundation

/// Namespace for the GitLab implementation of the `CodeHost` protocol.
///
/// The implementation wraps the `glab` CLI. It is the only code that knows GitLab wire
/// values (GraphQL enums, `glab` JSON shapes, REST paths); it returns the
/// provider-neutral model from `CodansCore`. See ADR 0004 items 1–3, 6–9, and 15.
///
/// Dependency rules (folder-level, enforced by review):
/// - May import `Foundation`, `CodansCore`, `codans/Process/` (`CommandRunner`), and the
///   shared `codans/CodeHost/` types.
/// - Must not import `codans/Git/`, `codans/Runtime/`, `codans/Hooks/`, SwiftUI, or TCA.
nonisolated enum GitLab {
  /// Oldest `glab` that has every command codans calls. 1.122.0 is the first release
  /// with `glab auth status --output json` (gitlab-org/cli!4028), which the resolver and
  /// the availability probe read. `glab api` and `glab version` are older.
  static let minimumVersion = "1.122.0"

  /// URL-encoded project path that the REST API takes as the project id
  /// (`group/sub/repo` → `group%2Fsub%2Frepo`).
  static func projectID(_ repository: CodeHostRepository) -> String {
    repository.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
      ?? repository.path
  }

  /// `true` when `host` carries a port (`192.168.2.158:8929`). `glab --hostname` rejects
  /// such a host, so codans passes it through `GITLAB_HOST` only.
  static func hostHasPort(_ host: String) -> Bool {
    host.contains(":")
  }

  /// Compares two dotted version strings numerically (`1.9.0` < `1.10.0`).
  static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
    let lhs = version.split(separator: ".").map { Int($0) ?? 0 }
    let rhs = minimum.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(lhs.count, rhs.count) {
      let left = index < lhs.count ? lhs[index] : 0
      let right = index < rhs.count ? rhs[index] : 0
      if left != right { return left > right }
    }
    return true
  }
}
