import Foundation

/// Catalog version 4 → 5: moves host fields from Remote Projects into the
/// Host list (ADR 0003).
///
/// Each distinct (Host, Username, Port) of the existing Remote Projects
/// becomes one `HostRecord`, in Project order, and those Projects refer to
/// it by id. Local Projects stay on This Mac. The recent-hosts list
/// (`saved-server-hosts.json`) is not migrated.
public nonisolated enum CatalogMigrationV4ToV5 {
  public static func migrate(_ catalog: Catalog) -> Catalog {
    var migrated = catalog
    migrated.version = 5
    migrated.adoptHostReferences()
    return migrated
  }
}
