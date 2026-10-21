import Foundation
import CodansCore
import os.log

/// What `CatalogStore.load` found. The app reads it to gate the session
/// reaper and the unread sweep (off on any loss or read-only outcome) and
/// to show the "update required" screen for a read-only catalog.
nonisolated struct CatalogLoadReport: Equatable, Sendable {
  /// The file declares a version above this build's. The catalog was not
  /// read, not moved, and will not be saved.
  var readOnlyVersion: Int?
  /// The file was migrated from this version at load; a copy of the
  /// original sits in `backups/`.
  var migratedFromVersion: Int?
  /// Tabs skipped because their record did not decode.
  var droppedTabs = 0
  /// Panes removed because every one of their Tabs dropped.
  var droppedPanes = 0

  var isReadOnly: Bool { readOnlyVersion != nil }
  var decodeLossCount: Int { droppedTabs + droppedPanes }
  /// A dropped Tab's session must not be reaped as an orphan, and a
  /// catalog this build cannot write must not have its sessions touched.
  var allowsSessionSweeps: Bool { !isReadOnly && decodeLossCount == 0 }

  static let clean = CatalogLoadReport()
}

@MainActor
class CatalogStore {
  private let fileURL: URL
  private let logger = Logger(subsystem: "com.gumpw.codans.persistence", category: "catalog")

  private var pendingSaveTask: Task<Void, Never>?
  private var latestCatalog: Catalog?
  /// False once `load` met a file it must not overwrite: one from a newer
  /// build, or one it could neither read nor back up. Every save is then
  /// dropped: an empty in-memory catalog must never replace a user's
  /// project list that is merely unreadable to this build.
  private(set) var persistenceEnabled = true
  /// Outcome of the last `load`; `.clean` before it runs.
  private(set) var loadReport: CatalogLoadReport = .clean

  init(fileURL: URL = Catalog.defaultURL()) {
    self.fileURL = fileURL
  }

  /// Reads the catalog. Outcomes, all recorded in `loadReport`:
  /// - a missing file reads as the default catalog;
  /// - a file of an older version is migrated in memory, a copy of the
  ///   original is kept in `backups/`, and the current shape is written
  ///   at once;
  /// - a file of a newer version is left untouched and the store goes
  ///   read-only (nothing is ever saved);
  /// - a current file decodes tolerantly, counting dropped records;
  /// - a corrupt file is moved into `backups/` and an empty catalog is
  ///   returned. Any failure that leaves an unreadable file in place
  ///   throws and disables saving.
  func load() throws -> Catalog {
    loadReport = .clean
    let data: Data?
    do {
      data = try Self.readData(at: fileURL)
    } catch {
      persistenceEnabled = false
      throw error
    }
    guard let data else { return .default }

    let outcome: CatalogLoadOutcome
    do {
      outcome = try CatalogLoader.decode(data)
    } catch Catalog.DecodingIssue.unsupportedVersion(let version) {
      return try setAside(reason: .unsupported(version: version))
    } catch is DecodingError {
      return try setAside(reason: .corrupt)
    } catch is Catalog.LayoutIssue {
      return try setAside(reason: .corrupt)
    }
    let decoded: Catalog
    switch outcome {
    case .readOnly(let version):
      loadReport.readOnlyVersion = version
      persistenceEnabled = false
      logger.error(
        "catalog.json is version \(version, privacy: .public); this build reads up to \(Catalog.currentVersion, privacy: .public). Read-only."
      )
      return .default
    case .migrated(let migrated, let fromVersion):
      decoded = try commitMigration(migrated, fromVersion: fromVersion)
    case .current(let catalog, let loss):
      decoded = catalog
      loadReport.droppedTabs = loss.droppedTabs
      loadReport.droppedPanes = loss.droppedPanes
      if !loss.isEmpty {
        logger.error(
          "catalog.json decoded with losses: \(loss.droppedTabs, privacy: .public) tab(s), \(loss.droppedPanes, privacy: .public) pane(s); session sweeps are off for this launch"
        )
      }
    }
    var existing = decoded
    // Self-heal Server projects whose `remoteHost` was stripped by an older
    // build sharing this catalog (tolerant decode + full re-encode drops
    // unknown keys). The sidecar is invisible to those builds, so it
    // survives; persist the healed catalog immediately so a crash before
    // the next debounced save can't lose the repair.
    var repaired = false
    if RemoteHostSidecar.repair(&existing, sidecarURL: sidecarURL) {
      logger.notice("restored remoteHost fields from sidecar")
      repaired = true
    }
    // Same failure, different field: a build predating `isWorkspace` drops
    // the key and may probe a `gitRoot` onto the workspace root. The
    // manifest on disk is the durable signal — re-derive the flag from it.
    if WorkspaceMarkerRepair.repair(&existing) {
      logger.notice("restored isWorkspace flags from workspace manifests")
      repaired = true
    }
    if repaired {
      try? saveNow(existing)
    }
    return existing
  }

  /// Older shape lifted in memory: keep a copy of the original under
  /// `backups/` (copy, never move — the file stays in place until the new
  /// shape is durably written), then write the current shape at once. A
  /// backup that fails leaves the file alone and disables saving, so the
  /// original can never be overwritten without its copy existing.
  private func commitMigration(_ migrated: Catalog, fromVersion: Int) throws -> Catalog {
    let reason = StoreBackup.Reason.migrated(fromVersion: fromVersion)
    do {
      let backup = try StoreBackup.prepareURL(for: fileURL, reason: reason)
      try FileManager.default.copyItem(at: fileURL, to: backup)
      StoreBackup.prune(for: fileURL, reason: reason)
      logger.notice(
        "backed up catalog.json v\(fromVersion, privacy: .public) to \(backup.lastPathComponent, privacy: .public)")
    } catch {
      persistenceEnabled = false
      logger.error("catalog.json v\(fromVersion, privacy: .public) backup failed; saving disabled: \(error)")
      throw error
    }
    loadReport.migratedFromVersion = fromVersion
    try saveNow(migrated)
    return migrated
  }

  private static func readData(at url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Data(contentsOf: url)
  }

  private func setAside(reason: StoreBackup.Reason) throws -> Catalog {
    do {
      let backup = try StoreBackup.moveAside(fileURL, reason: reason)
      logger.error("catalog.json unreadable; backed up to \(backup.lastPathComponent, privacy: .public), starting empty")
      return .default
    } catch {
      persistenceEnabled = false
      logger.error("catalog.json unreadable and backup failed; saving disabled: \(error)")
      throw error
    }
  }

  private var sidecarURL: URL {
    RemoteHostSidecar.url(alongsideCatalogAt: fileURL)
  }

  func scheduleSave(_ catalog: Catalog) {
    guard persistenceEnabled else { return }
    latestCatalog = catalog

    pendingSaveTask?.cancel()
    pendingSaveTask = Task {
      try? await Task.sleep(nanoseconds: 500_000_000)

      guard !Task.isCancelled else { return }

      if let toSave = latestCatalog {
        do {
          try saveNow(toSave)
        } catch {
          // Deliberately leave the on-disk file alone. `AtomicFileStore.write`
          // only ever renames a fully-written temp file over the target, so a
          // failed save means the *previous* catalog is still intact and still
          // the best copy we have. Moving it aside here (as this path used to)
          // turned a transient ENOSPC into total config loss: the next launch
          // found no file and loaded `.default` — an empty project list.
          logger.error("Failed to save catalog (on-disk copy left intact): \(error)")
        }
      }
    }
  }

  func saveNow(_ catalog: Catalog) throws {
    guard persistenceEnabled else { return }
    try AtomicFileStore.write(catalog, to: fileURL)
    // Mirror Server-project connections into the sidecar on every save, so
    // the repair source stays current without a separate write path.
    RemoteHostSidecar.sync(from: catalog, to: sidecarURL)
  }

  /// Synchronous flush for app termination. Cancels the pending debounced
  /// task and writes `latestCatalog` immediately so the last sidebar
  /// mutation (selection / expansion / tag-filter change) is not dropped
  /// when the user quits within the 500 ms debounce window.
  func flushPending() {
    pendingSaveTask?.cancel()
    pendingSaveTask = nil
    guard let toSave = latestCatalog else { return }
    do {
      try saveNow(toSave)
    } catch {
      logger.error("Failed to flush catalog on termination: \(error)")
    }
  }
}

extension Catalog {
  static let `default` = Catalog()
}
