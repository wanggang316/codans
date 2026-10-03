import Foundation

/// The one place a persisted store sets a file aside before replacing or
/// abandoning it — a migration's original, a file that failed to decode, or a
/// file written by a newer build.
///
/// Every backup lands in a `backups/` directory next to the file, named
/// `<stem>.<reason>-<yyyyMMdd'T'HHmmss'Z'>.<ext>` (e.g.
/// `backups/settings.migrated-v2-20261003T101500Z.json`), so the store's own
/// directory only ever holds live files. Only the newest `retainedPerReason`
/// backups of one file for one reason are kept.
///
/// Policy shared by every caller: a file that could not be read is never
/// overwritten unless `moveAside` succeeded first.
public nonisolated enum StoreBackup {
  public enum Reason: Equatable, Sendable {
    /// Original of a file just migrated from `fromVersion` to the current shape.
    case migrated(fromVersion: Int)
    /// File present but undecodable.
    case corrupt
    /// File declares a version this build cannot read (newer, or retired).
    case unsupported(version: Int)

    var label: String {
      switch self {
      case .migrated(let version): return "migrated-v\(version)"
      case .corrupt: return "corrupt"
      case .unsupported(let version): return "unsupported-v\(version)"
      }
    }
  }

  public static let directoryName = "backups"
  public static let retainedPerReason = 5

  /// `<url's directory>/backups/`.
  public static func directory(for url: URL) -> URL {
    url.deletingLastPathComponent().appendingPathComponent(directoryName, isDirectory: true)
  }

  /// Creates `backups/` if needed and returns a free URL for a backup of
  /// `url`. Does not move anything — for callers that must order the move
  /// themselves (the settings migration's three-step rename).
  public static func prepareURL(
    for url: URL,
    reason: Reason,
    at date: Date = Date(),
    fileManager: FileManager = .default
  ) throws -> URL {
    let directory = directory(for: url)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let base = "\(prefix(for: url, reason: reason))\(timestamp(date))"
    let ext = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
    var candidate = directory.appendingPathComponent(base + ext, isDirectory: false)
    var counter = 1
    while fileManager.fileExists(atPath: candidate.path) {
      candidate = directory.appendingPathComponent("\(base)-\(counter)\(ext)", isDirectory: false)
      counter += 1
    }
    return candidate
  }

  /// Moves `url` into `backups/` and prunes older backups of the same file
  /// and reason. Throws when the move fails; the caller must then leave the
  /// original alone.
  @discardableResult
  public static func moveAside(
    _ url: URL,
    reason: Reason,
    at date: Date = Date(),
    fileManager: FileManager = .default
  ) throws -> URL {
    let backup = try prepareURL(for: url, reason: reason, at: date, fileManager: fileManager)
    try fileManager.moveItem(at: url, to: backup)
    prune(for: url, reason: reason, fileManager: fileManager)
    return backup
  }

  /// Deletes all but the newest `keep` backups of `url` for `reason`.
  /// Timestamps sort lexically, so name order is age order. Best effort.
  public static func prune(
    for url: URL,
    reason: Reason,
    keep: Int = retainedPerReason,
    fileManager: FileManager = .default
  ) {
    let directory = directory(for: url)
    let prefix = prefix(for: url, reason: reason)
    guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
    let matching = names.filter { $0.hasPrefix(prefix) }.sorted(by: >)
    for name in matching.dropFirst(keep) {
      try? fileManager.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  /// `yyyyMMdd'T'HHmmss'Z'` in UTC — sortable, and free of `:` so Finder and
  /// shell globs handle it.
  public static func timestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  private static func prefix(for url: URL, reason: Reason) -> String {
    "\(url.deletingPathExtension().lastPathComponent).\(reason.label)-"
  }
}
