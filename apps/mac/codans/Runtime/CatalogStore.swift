import Foundation
import CodansCore
import os.log

@MainActor
class CatalogStore {
  private let fileURL: URL
  private let logger = Logger(subsystem: "com.gumpw.codans.persistence", category: "catalog")

  private var pendingSaveTask: Task<Void, Never>?
  private var latestCatalog: Catalog?
  /// False once `load` met a file it could neither read nor back up. Every
  /// save is then dropped: an empty in-memory catalog must never replace a
  /// user's project list that is merely unreadable to this build.
  private(set) var persistenceEnabled = true

  init(fileURL: URL = Catalog.defaultURL()) {
    self.fileURL = fileURL
  }

  /// A corrupt file, or one from a newer (or retired) catalog version, is
  /// moved into `backups/` and an empty catalog is returned. Any failure
  /// that leaves the unreadable file in place throws and disables saving.
  func load() throws -> Catalog {
    let decoded: Catalog?
    do {
      decoded = try AtomicFileStore.read(Catalog.self, at: fileURL)
    } catch Catalog.DecodingIssue.unsupportedVersion(let version) {
      return try setAside(reason: .unsupported(version: version))
    } catch is DecodingError {
      return try setAside(reason: .corrupt)
    } catch {
      persistenceEnabled = false
      throw error
    }
    if var existing = decoded {
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
    return .default
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
