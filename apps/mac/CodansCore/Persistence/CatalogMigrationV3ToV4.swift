import Foundation

/// Catalog version 3 → 4: places every Workspace row into a group.
///
/// Runs on a catalog whose layout `CatalogMigrationV4ToV5` has already
/// lifted, so it leaves `version` alone. Pure and deterministic, so a crash
/// before the migrated write repeats the same result. Rows keep their IDs
/// and Panes (session identity); only `workspaceSlot` and the Project's
/// `workspaceGroups` are added.
public nonisolated enum CatalogMigrationV3ToV4 {
  public static func migrate(_ catalog: Catalog) -> Catalog {
    var migrated = catalog
    for index in migrated.projects.indices where migrated.projects[index].isWorkspace {
      migrateWorkspace(&migrated.projects[index])
    }
    return migrated
  }

  /// The old root row becomes the terminal of a named group `existing`
  /// rooted at the Workspace root; every other row, archived ones included,
  /// becomes its member. `default` starts without rows: its directory and
  /// references are created by the Workspace reconcile.
  private static func migrateWorkspace(_ project: inout Project) {
    guard project.workspaceGroups.isEmpty else { return }
    let defaultID = WorkspaceGroupID.derived(
      rootPath: project.rootPath, key: WorkspaceLayout.defaultGroupName)
    let existingID = WorkspaceGroupID.derived(
      rootPath: project.rootPath, key: WorkspaceLayout.migratedGroupName)
    project.workspaceGroups = [
      WorkspaceGroupRecord(id: defaultID, name: WorkspaceLayout.defaultGroupName, kind: .default),
      WorkspaceGroupRecord(id: existingID, name: WorkspaceLayout.migratedGroupName, kind: .named),
    ]
    for rowIndex in project.worktrees.indices {
      let role: WorkspaceSlot.Role =
        project.isMainCheckout(project.worktrees[rowIndex]) ? .groupTerminal : .member
      project.worktrees[rowIndex].workspaceSlot = WorkspaceSlot(groupID: existingID, role: role)
    }
  }
}
