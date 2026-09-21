import Foundation

/// Re-derives `Project.isWorkspace` from the manifest on disk after an older
/// build has stripped the key.
///
/// The dev catalog is shared by every branch's Debug build. A build that
/// predates `isWorkspace` decodes tolerantly, drops the key, and — worse —
/// runs its folder-project git probe on the workspace root: if the root sits
/// inside some repository it persists that as `gitRoot`, and the next save
/// leaves a workspace masquerading as an ordinary repo whose reconcile would
/// archive every child. The manifest is a file those builds never touch, so
/// it is the durable signal. Same instinct as `RemoteHostSidecar`, with the
/// workspace's own metadata standing in for the sidecar.
public nonisolated enum WorkspaceMarkerRepair {
  /// Marks every local, non-workspace project whose root carries a manifest
  /// as a workspace and clears any `gitRoot` a stripped build may have
  /// probed onto it. Returns whether anything changed so the caller can
  /// persist the healed catalog. `hasManifest` is injectable for tests; the
  /// default is a single `stat` per candidate project.
  @discardableResult
  public static func repair(
    _ catalog: inout Catalog,
    hasManifest: (String) -> Bool = { WorkspaceManifestStore.hasManifest(rootPath: $0) }
  ) -> Bool {
    var repaired = false
    for index in catalog.projects.indices {
      let project = catalog.projects[index]
      guard project.remoteHost == nil, !project.isWorkspace else { continue }
      guard hasManifest(project.rootPath) else { continue }
      catalog.projects[index].isWorkspace = true
      catalog.projects[index].gitRoot = nil
      repaired = true
    }
    return repaired
  }
}
