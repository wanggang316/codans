import Foundation

/// Workspace manifest version 1 → group manifest (schema 2).
///
/// Pure and deterministic: the same version 1 manifest and root give the
/// same result, including IDs, so a crash before the write or a second app
/// instance on the same root repeats it exactly. Version 1 checkouts become
/// members of the named group `existing`, rooted at the Workspace root, so
/// no directory moves.
public nonisolated enum WorkspaceManifestMigration {
  /// - Parameters:
  ///   - manifest: the normalized version 1 manifest.
  ///   - rootPath: the Workspace root, spelled as the catalog stores it.
  ///   - pathExists: whether a path is taken on disk; picks a free folder
  ///     for `default`.
  public static func migrate(
    _ manifest: WorkspaceManifest,
    rootPath: String,
    pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> WorkspaceGroupsManifest {
    let members = manifest.repositories.map { entry in
      WorkspaceGroupsManifest.Member(
        id: WorkspaceMemberID.derived(rootPath: rootPath, path: entry.path),
        name: entry.name,
        path: entry.path,
        sourceGitRoot: entry.sourceGitRoot,
        role: entry.role,
        checkoutMode: entry.checkoutMode,
        branch: entry.branch,
        baseRef: entry.baseRef)
    }
    let defaultGroup = WorkspaceGroupsManifest.Group(
      id: WorkspaceGroupID.derived(rootPath: rootPath, key: WorkspaceLayout.defaultGroupName),
      name: WorkspaceLayout.defaultGroupName,
      kind: .default,
      path: defaultFolder(rootPath: rootPath, taken: Set(members.map(\.path)), pathExists: pathExists))
    let existing = WorkspaceGroupsManifest.Group(
      id: WorkspaceGroupID.derived(rootPath: rootPath, key: WorkspaceLayout.migratedGroupName),
      name: WorkspaceLayout.migratedGroupName,
      kind: .named,
      path: WorkspaceLayout.migratedGroupPath,
      origin: .migrated,
      members: members)
    return WorkspaceGroupsManifest(
      title: manifest.title,
      description: manifest.description,
      taskLinks: manifest.taskLinks,
      projects: sources(of: manifest.repositories),
      groups: [defaultGroup, existing],
      createdAt: manifest.createdAt,
      updatedAt: manifest.updatedAt)
  }

  /// One source per distinct `sourceGitRoot`, in entry order, named after
  /// the repository folder and suffixed `-2`, `-3`, … on a name clash.
  /// Entries without a recorded source contribute no project.
  private static func sources(of entries: [WorkspaceManifest.Entry]) -> [WorkspaceGroupsManifest.Source] {
    var result: [WorkspaceGroupsManifest.Source] = []
    var seenRoots = Set<String>()
    var usedNames = Set<String>()
    for entry in entries {
      guard let root = entry.sourceGitRoot, seenRoots.insert(root).inserted else { continue }
      let folder = (root as NSString).lastPathComponent
      let base = folder.isEmpty ? entry.name : folder
      var name = base
      var suffix = 2
      while usedNames.contains(name) {
        name = "\(base)-\(suffix)"
        suffix += 1
      }
      usedNames.insert(name)
      let remoteURL = entries.first { $0.sourceGitRoot == root && $0.remoteURL != nil }?.remoteURL
      result.append(WorkspaceGroupsManifest.Source(name: name, sourceGitRoot: root, remoteURL: remoteURL))
    }
    return result
  }

  /// First of `default`, `default-2`, … that is neither a member path nor
  /// present under the root.
  private static func defaultFolder(
    rootPath: String,
    taken: Set<String>,
    pathExists: (String) -> Bool
  ) -> String {
    var suffix = 1
    while true {
      let name =
        suffix == 1 ? WorkspaceLayout.defaultGroupName : "\(WorkspaceLayout.defaultGroupName)-\(suffix)"
      let path = (rootPath as NSString).appendingPathComponent(name)
      if !taken.contains(name), !pathExists(path) { return name }
      suffix += 1
    }
  }
}
