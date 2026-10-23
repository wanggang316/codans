import Foundation

/// How to remove a Workspace. Both modes keep every source main checkout.
public nonisolated enum WorkspaceRemovalRequest: Equatable, Sendable {
  /// Remove the catalog entry only. Disk unchanged.
  case sidebarOnly
  /// Delete every named group, the default links and directory, then the
  /// root when every group is gone and the root is owned. The catalog entry
  /// goes only on full success.
  case deleteOwnedFiles(GroupDeletionRequest)
}
