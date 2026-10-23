import Foundation

/// The single check every Workspace deletion path calls before it removes a
/// directory.
///
/// A path is owned only when all of these hold:
/// - its standardized form (`.` and `..` removed, no symlink resolution) is
///   strictly inside the Workspace root;
/// - it is a recorded group directory or member path of the manifest;
/// - no component from the root down to it is a symbolic link (`lstat`), so
///   a delete cannot follow a `default` link into a source checkout;
/// - its canonical form is not equal to or inside any source project.
///
/// The root itself (the migrated `.` group) is never owned.
public nonisolated enum WorkspaceOwnership {
  public enum Rejection: Equatable, Sendable {
    case outsideRoot
    case workspaceRoot
    case notRecorded
    case symbolicLink(String)
    case insideSource(String)
  }

  public enum Verdict: Equatable, Sendable {
    case owned
    case notOwned(Rejection)
  }

  /// - Parameters:
  ///   - path: absolute path to check.
  ///   - rootPath: the canonical Workspace root, as the catalog stores it.
  public static func check(
    path: String,
    rootPath: String,
    manifest: WorkspaceGroupsManifest,
    fileManager: FileManager = .default
  ) -> Verdict {
    let root = URL(fileURLWithPath: rootPath).standardizedFileURL.pathComponents
    let target = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    guard target.starts(with: root) else { return .notOwned(.outsideRoot) }
    let relative = Array(target.dropFirst(root.count))
    guard !relative.isEmpty else { return .notOwned(.workspaceRoot) }
    let relativePath = relative.joined(separator: "/")
    guard recordedPaths(of: manifest).contains(relativePath) else { return .notOwned(.notRecorded) }

    var current = URL(fileURLWithPath: rootPath).standardizedFileURL
    for component in relative {
      current.appendPathComponent(component)
      if isSymbolicLink(current.path, fileManager: fileManager) {
        return .notOwned(.symbolicLink(current.path))
      }
    }

    let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().pathComponents
    for source in manifest.projects {
      let sourceComponents = URL(fileURLWithPath: source.sourceGitRoot).resolvingSymlinksInPath().pathComponents
      if canonical.starts(with: sourceComponents) {
        return .notOwned(.insideSource(source.sourceGitRoot))
      }
    }
    return .owned
  }

  /// Group directories other than the root, and member paths.
  private static func recordedPaths(of manifest: WorkspaceGroupsManifest) -> Set<String> {
    var paths = Set<String>()
    for group in manifest.groups {
      if group.path != WorkspaceLayout.migratedGroupPath { paths.insert(group.path) }
      for member in group.members { paths.insert(member.path) }
    }
    return paths
  }

  private static func isSymbolicLink(_ path: String, fileManager: FileManager) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(atPath: path) else { return false }
    return attributes[.type] as? FileAttributeType == .typeSymbolicLink
  }
}
