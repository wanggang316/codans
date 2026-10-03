import Foundation
import os.log

/// On-disk envelope format for `~/.codans/state/notifications.json`.
///
/// Owns load/save and the legacy → envelope upgrade. The v1.0 shape was a
/// bare top-level JSON array of `InboxEntry`; v1.1 wraps that array in a
/// `{ version, entries }` envelope so future schema bumps have a place to
/// declare themselves. The loader accepts both shapes; the saver only ever
/// writes the envelope form, so the first save after an upgrade rewrites
/// any pre-v1.1 file in place (single round-trip, no user-visible step).
///
/// Forward-version files (a file whose `version` exceeds what this build
/// understands, e.g. user downgraded after a v1.2 build wrote v2) are
/// quarantined through `StoreBackup` and the inbox starts empty for that
/// launch. The quarantine path is surfaced through `LoadResult`
/// so the "Inbox reset" toast can name the backup file.
public nonisolated enum InboxFile {
  /// Current envelope version this build writes and the maximum it can read.
  public static let currentVersion: Int = 1

  /// Wire shape persisted to disk. `entries` carries the inbox; `version`
  /// guards forward compatibility for downgraded builds.
  public struct Envelope: Codable, Sendable {
    public let version: Int
    public let entries: [InboxEntry]

    public init(version: Int, entries: [InboxEntry]) {
      self.version = version
      self.entries = entries
    }
  }

  /// Result of `load`. `quarantineBackupURL` is non-nil only when the file
  /// on disk announced a `version` greater than `currentVersion` and was
  /// renamed aside; consumers can surface the backup basename in UI.
  public struct LoadResult: Sendable {
    public let entries: [InboxEntry]
    public let quarantineBackupURL: URL?

    public init(entries: [InboxEntry], quarantineBackupURL: URL? = nil) {
      self.entries = entries
      self.quarantineBackupURL = quarantineBackupURL
    }
  }

  private static let logger = Logger(
    subsystem: "com.gumpw.codans.persistence",
    category: "notifications.inbox-file"
  )

  /// Read the inbox from `url`.
  ///
  /// - Returns `nil` when the file is absent (fresh install).
  /// - Returns `LoadResult(entries: [], quarantineBackupURL: <path>)` and
  ///   moves the file into `backups/` when its envelope `version` exceeds
  ///   `currentVersion`.
  /// - Reads both envelope and legacy bare-array shapes. A legacy file is
  ///   returned as-is; the next `save(_:to:)` rewrites it in envelope form.
  /// - Returns `LoadResult(entries: [])` when the bytes are neither a valid
  ///   envelope nor a valid bare array, after moving them into `backups/`.
  /// - Throws when an unreadable file could not be backed up; the caller must
  ///   then not save over it.
  public static func load(from url: URL, now: Date = Date()) throws -> LoadResult? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else { return nil }

    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder.touchCodeDefault

    if let envelope = try? decoder.decode(Envelope.self, from: data) {
      if envelope.version <= currentVersion {
        return LoadResult(entries: envelope.entries)
      }

      // Forward-version file: move aside, start empty.
      let backup = try StoreBackup.moveAside(url, reason: .unsupported(version: envelope.version), at: now)
      return LoadResult(entries: [], quarantineBackupURL: backup)
    }

    if let legacy = try? decoder.decode([InboxEntry].self, from: data) {
      return LoadResult(entries: legacy)
    }

    let backup = try StoreBackup.moveAside(url, reason: .corrupt, at: now)
    logger.warning(
      "Inbox file at \(url.path, privacy: .public) is unparseable; backed up to \(backup.lastPathComponent, privacy: .public)"
    )
    return LoadResult(entries: [])
  }

  /// Encode `entries` as an envelope at `currentVersion` and atomically
  /// rename it over `url`. Delegates the durability story to
  /// `AtomicFileStore.write`.
  public static func save(_ entries: [InboxEntry], to url: URL) throws {
    let envelope = Envelope(version: currentVersion, entries: entries)
    try AtomicFileStore.write(envelope, to: url)
  }
}
