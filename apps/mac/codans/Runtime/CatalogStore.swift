import CodansCore
import Foundation
import os.log

@MainActor
class CatalogStore {
  private let fileURL: URL
  private let logger = Logger(subsystem: "com.gumpw.codans.persistence", category: "catalog")

  private var pendingSaveTask: Task<Void, Never>?
  private var latestCatalog: Catalog?
  /// False once `load` met a file it must not overwrite: one it could
  /// neither read nor back up, one from a newer build, or a migrated file
  /// whose original could not be backed up. Every save is then dropped: an
  /// in-memory catalog must never replace a user's project list that this
  /// build cannot read or cannot restore.
  private(set) var persistenceEnabled = true
  /// Why `load` turned saving off, for the one launch alert. `nil` when the
  /// catalog loaded normally.
  private(set) var loadIssue: LoadIssue?

  enum LoadIssue: Equatable {
    /// The file was written by a newer build. It stays in place unchanged.
    case newerVersion(Int)
    /// A migration ran, but the original could not be copied to `backups/`,
    /// so the migrated catalog lives in memory only.
    case migrationBackupFailed
  }

  init(fileURL: URL = Catalog.defaultURL()) {
    self.fileURL = fileURL
  }

  /// A store that never reads or writes. The XCTest host app uses it so a
  /// test run cannot migrate or overwrite the developer's catalog, which
  /// other builds of the same channel share.
  static func detached() -> CatalogStore {
    let store = CatalogStore(fileURL: URL(fileURLWithPath: "/dev/null"))
    store.persistenceEnabled = false
    return store
  }

  /// Reads the catalog and brings it to `Catalog.currentVersion`.
  ///
  /// - An older readable version is migrated in memory, the original is
  ///   copied to `backups/`, and the result is written at once.
  /// - A newer version stays in place (with a copy in `backups/`); saving is
  ///   turned off and an empty catalog is returned.
  /// - A corrupt or retired file is moved into `backups/` and an empty
  ///   catalog is returned.
  /// Any failure that leaves an unreadable file in place throws and turns
  /// saving off.
  func load() throws -> Catalog {
    let decoded: Catalog?
    do {
      decoded = try AtomicFileStore.read(Catalog.self, at: fileURL)
    } catch Catalog.DecodingIssue.newerVersion(let version) {
      return keepNewerFile(version: version)
    } catch Catalog.DecodingIssue.unsupportedVersion(let version) {
      return try setAside(reason: .unsupported(version: version))
    } catch is DecodingError {
      return try setAside(reason: .corrupt)
    } catch {
      persistenceEnabled = false
      throw error
    }
    guard var existing = decoded else { return .default }
    // Self-heal Server projects whose `remoteHost` was stripped by an older
    // build sharing this catalog (tolerant decode + full re-encode drops
    // unknown keys). The sidecar is invisible to those builds, so it
    // survives; persist the healed catalog immediately so a crash before
    // the next debounced save can't lose the repair.
    var needsSave = false
    if RemoteHostSidecar.repair(&existing, sidecarURL: sidecarURL) {
      logger.notice("restored remoteHost fields from sidecar")
      needsSave = true
    }
    // Same failure, different field: a build predating `isWorkspace` drops
    // the key and may probe a `gitRoot` onto the workspace root. The
    // manifest on disk is the durable signal — re-derive the flag from it.
    // Runs before the migration so a repaired Workspace gets its groups.
    if WorkspaceMarkerRepair.repair(&existing) {
      logger.notice("restored isWorkspace flags from workspace manifests")
      needsSave = true
    }
    if existing.version < Catalog.currentVersion {
      let fromVersion = existing.version
      existing = CatalogMigrationV3ToV4.migrate(existing)
      do {
        try StoreBackup.copyAside(fileURL, reason: .migrated(fromVersion: fromVersion))
      } catch {
        persistenceEnabled = false
        loadIssue = .migrationBackupFailed
        logger.error("catalog.json v\(fromVersion) backup failed; migrated in memory, saving disabled: \(error)")
        return existing
      }
      logger.notice("migrated catalog.json from v\(fromVersion) to v\(Catalog.currentVersion)")
      needsSave = true
    }
    if needsSave {
      try? saveNow(existing)
    }
    return existing
  }

  /// A newer build owns this file. Keep it byte-identical: no move, no
  /// save. The copy in `backups/` is best effort, for the case where the
  /// user deletes the file to recover.
  private func keepNewerFile(version: Int) -> Catalog {
    persistenceEnabled = false
    loadIssue = .newerVersion(version)
    do {
      try StoreBackup.copyAside(fileURL, reason: .unsupported(version: version))
    } catch {
      logger.error("catalog.json v\(version) backup copy failed: \(error)")
    }
    logger.error("catalog.json is v\(version), newer than this build; saving disabled")
    return .default
  }

  private func setAside(reason: StoreBackup.Reason) throws -> Catalog {
    do {
      let backup = try StoreBackup.moveAside(fileURL, reason: reason)
      logger.error(
        "catalog.json unreadable; backed up to \(backup.lastPathComponent, privacy: .public), starting empty")
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
