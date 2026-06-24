import Foundation
import os.log

/// On-disk envelope format for `~/.config/codans/notifications.json`.
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
/// quarantined to a deterministic sibling path and the inbox starts empty
/// for that launch. The quarantine path is surfaced through `LoadResult`
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
  ///   renames the file aside when its envelope `version` exceeds
  ///   `currentVersion`. The rename target is `quarantinePath(for:at:)`.
  /// - Reads both envelope and legacy bare-array shapes. A legacy file is
  ///   returned as-is; the next `save(_:to:)` rewrites it in envelope form.
  /// - Returns `LoadResult(entries: [])` (no rename) when the bytes are
  ///   neither a valid envelope nor a valid bare array. The next save will
  ///   overwrite the corrupt bytes.
  public static func load(from url: URL, now: Date = Date()) throws -> LoadResult? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: url.path) else { return nil }

    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder.touchCodeDefault

    if let envelope = try? decoder.decode(Envelope.self, from: data) {
      if envelope.version <= currentVersion {
        return LoadResult(entries: envelope.entries)
      }

      // Forward-version file: rename aside, start empty. A rename failure
      // is logged but non-fatal — the file is unreadable to us either way.
      let target = quarantinePath(for: url, at: now)
      do {
        try fileManager.moveItem(at: url, to: target)
        return LoadResult(entries: [], quarantineBackupURL: target)
      } catch {
        logger.error(
          "Failed to quarantine forward-version inbox file: \(String(describing: error), privacy: .public)"
        )
        return LoadResult(entries: [])
      }
    }

    if let legacy = try? decoder.decode([InboxEntry].self, from: data) {
      return LoadResult(entries: legacy)
    }

    logger.warning("Inbox file at \(url.path, privacy: .public) is unparseable; starting empty")
    return LoadResult(entries: [])
  }

  /// Encode `entries` as an envelope at `currentVersion` and atomically
  /// rename it over `url`. Delegates the durability story to
  /// `AtomicFileStore.write`.
  public static func save(_ entries: [InboxEntry], to url: URL) throws {
    let envelope = Envelope(version: currentVersion, entries: entries)
    try AtomicFileStore.write(envelope, to: url)
  }

  /// Deterministic quarantine path for a forward-version file. The format
  /// is `<original-path>.bak-<yyyyMMdd'T'HHmmss'Z'>` in UTC; the basic
  /// ISO 8601 form keeps the path filesystem-safe across platforms and
  /// sorts lexicographically by time.
  ///
  /// Pure — `at:` is injected so tests can pin the timestamp and the
  /// loader can pass through its own `now` parameter.
  public static func quarantinePath(for url: URL, at: Date) -> URL {
    let timestamp = quarantineFormatter.string(from: at)
    let directory = url.deletingLastPathComponent()
    let renamed = "\(url.lastPathComponent).bak-\(timestamp)"
    return directory.appendingPathComponent(renamed)
  }

  // ISO 8601 basic profile (`yyyyMMdd'T'HHmmss'Z'`) in UTC. We avoid
  // `ISO8601DateFormatter` because its options for emitting the basic
  // form without separators are awkward; a one-shot `DateFormatter` with
  // a fixed `en_US_POSIX` locale is shorter and more obvious.
  private static let quarantineFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter
  }()
}
