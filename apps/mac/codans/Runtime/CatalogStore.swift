import Foundation
import CodansCore
import os.log

@MainActor
class CatalogStore {
  private let fileURL: URL
  private let logger = Logger(subsystem: "com.gumpw.codans.persistence", category: "catalog")

  private var pendingSaveTask: Task<Void, Never>?
  private var latestCatalog: Catalog?

  init(fileURL: URL = Catalog.defaultURL()) {
    self.fileURL = fileURL
  }

  func load() throws -> Catalog {
    if var existing = try AtomicFileStore.read(Catalog.self, at: fileURL) {
      // Self-heal Server projects whose `remoteHost` was stripped by an older
      // build sharing this catalog (tolerant decode + full re-encode drops
      // unknown keys). The sidecar is invisible to those builds, so it
      // survives; persist the healed catalog immediately so a crash before
      // the next debounced save can't lose the repair.
      if RemoteHostSidecar.repair(&existing, sidecarURL: sidecarURL) {
        logger.notice("restored remoteHost fields from sidecar")
        try? saveNow(existing)
      }
      return existing
    }
    return .default
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
