import Foundation
import os.log

/// Persistent store for the per-pane `SessionCatalog`. Mirrors the
/// debounced atomic-rename loop used by the in-app catalog store: a
/// 500 ms timer coalesces bursts of mutations, and `flushPending()` is
/// available for synchronous flush at app termination.
///
/// `@MainActor` — the catalog is read on launch and written from the
/// pane-lifecycle paths that already run on the main actor. Off-main
/// callers would race with the debounce bookkeeping.
@MainActor
public final class SessionStore {
  private let fileURL: URL
  private let logger = Logger(subsystem: "com.touch-code.runtime", category: "runtime.session")

  private var pendingSaveTask: Task<Void, Never>?
  private var latestCatalog: SessionCatalog?

  public init(fileURL: URL) throws {
    self.fileURL = fileURL
  }

  /// Read the on-disk catalog. Returns `.empty` for both a missing file
  /// and any decode failure (the corrupt payload is renamed aside so a
  /// user can inspect it after the fact). A `version` higher than the
  /// current schema is treated the same way as a decode failure, except
  /// the file is left untouched on disk — newer touch-code builds may
  /// still own it.
  public func load() throws -> SessionCatalog {
    let fm = FileManager.default
    guard fm.fileExists(atPath: fileURL.path) else { return .empty }

    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      logger.error("Failed to read sessions.json: \(error.localizedDescription, privacy: .public)")
      throw SessionStoreError.decode(error.localizedDescription)
    }

    let decoded: SessionCatalog
    do {
      decoded = try JSONDecoder().decode(SessionCatalog.self, from: data)
    } catch {
      // The corrupt file is renamed rather than deleted so the user can
      // inspect what went wrong and so this code stays crash-free even
      // when on-disk state is hostile.
      logger.error(
        "Failed to decode sessions.json (\(error.localizedDescription, privacy: .public)); backing up corrupt file."
      )
      backupCorruptFile()
      return .empty
    }

    guard decoded.version <= SessionCatalog.currentVersion else {
      // Forward-compat: a future touch-code build wrote a newer schema.
      // Refuse to interpret the payload but leave it on disk so that
      // future build remains the source of truth.
      logger.notice(
        "sessions.json version \(decoded.version) is newer than supported \(SessionCatalog.currentVersion); ignoring."
      )
      return .empty
    }

    return decoded
  }

  /// Coalescing write. The latest `catalog` overrides any earlier
  /// pending value; the timer fires 500 ms after the most-recent call.
  public func scheduleSave(_ catalog: SessionCatalog) {
    latestCatalog = catalog

    pendingSaveTask?.cancel()
    pendingSaveTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      await self.runPendingSave()
    }
  }

  /// Immediate, blocking save. Encodes pretty + sorted keys for stable
  /// diffs in tests and version-control friendliness.
  public func saveNow(_ catalog: SessionCatalog) throws {
    do {
      try AtomicFileStore.write(catalog, to: fileURL)
    } catch {
      throw SessionStoreError.write(error.localizedDescription)
    }
  }

  /// Synchronous flush for app termination. Cancels any pending timer
  /// and writes the most-recent catalog so the last mutation is not
  /// dropped inside the 500 ms debounce window.
  public func flushPending() {
    pendingSaveTask?.cancel()
    pendingSaveTask = nil
    guard let toSave = latestCatalog else { return }
    do {
      try saveNow(toSave)
    } catch {
      logger.error(
        "Failed to flush sessions.json on termination: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func runPendingSave() {
    guard let toSave = latestCatalog else { return }
    do {
      try saveNow(toSave)
    } catch {
      logger.error("Failed to save sessions.json: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func backupCorruptFile() {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let backupURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(timestamp).bak")
    try? FileManager.default.moveItem(at: fileURL, to: backupURL)
  }
}

public enum SessionStoreError: Error, Equatable {
  case decode(String)
  case write(String)
  /// Reserved for the flock-based single-writer guard that will land
  /// alongside the daemon-spawn path.
  case alreadyHeld
}
