import Foundation

/// What a store gets back for the bytes of a `catalog.json`.
public nonisolated enum CatalogLoadOutcome {
  /// The current version. `loss` counts the records the tolerant decode
  /// dropped; a non-empty loss gates the session reaper and the unread
  /// sweep for the launch.
  case current(Catalog, loss: CatalogDecodeLoss)
  /// An older version lifted in memory. The store backs up the original
  /// and writes the result before anything else touches the file.
  case migrated(Catalog, fromVersion: Int)
  /// Written by a newer build. The store leaves the file untouched and
  /// saves nothing.
  case readOnly(version: Int)

  public var catalog: Catalog? {
    switch self {
    case .current(let catalog, _), .migrated(let catalog, _): return catalog
    case .readOnly: return nil
    }
  }
}

/// Decides, from the `version` field alone, how to read a catalog
/// document, then decodes it. File I/O stays with the caller.
public nonisolated enum CatalogLoader {
  /// - Throws: `Catalog.DecodingIssue.unsupportedVersion` for a version
  ///   below `Catalog.oldestMigratableVersion`; a `DecodingError` for a
  ///   document without a readable `version` or with a record the current
  ///   shape cannot read; `Catalog.LayoutIssue` for a decoded or migrated
  ///   Worktree that breaks an invariant.
  public static func decode(_ data: Data) throws -> CatalogLoadOutcome {
    let version = try Catalog.peekVersion(in: data)
    switch Catalog.DecodingIssue.classify(version) {
    case nil:
      let loss = CatalogDecodeLoss()
      let decoder = JSONDecoder()
      loss.attach(to: decoder)
      let catalog = try decoder.decode(Catalog.self, from: data)
      try catalog.validateLayouts()
      return .current(catalog, loss: loss)
    case .needsMigration(let version):
      return .migrated(try CatalogMigrationV3ToV4.migrate(v3: data), fromVersion: version)
    case .newerVersion(let version):
      return .readOnly(version: version)
    case .unsupportedVersion(let version):
      throw Catalog.DecodingIssue.unsupportedVersion(version)
    }
  }
}
