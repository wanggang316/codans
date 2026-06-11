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
    if let existing = try AtomicFileStore.read(Catalog.self, at: fileURL) {
      return existing
    }
    return .default
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
          logger.error("Failed to save catalog: \(error)")
          backupBrokenFile()
        }
      }
    }
  }

  func saveNow(_ catalog: Catalog) throws {
    try AtomicFileStore.write(catalog, to: fileURL)
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

  private func backupBrokenFile() {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let backupURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent("catalog.json.broken-\(timestamp)")
    try? FileManager.default.moveItem(at: fileURL, to: backupURL)
  }
}

extension Catalog {
  static let `default` = Catalog()
}
