import Darwin
import Foundation
import os.log

/// One-time move from the pre-split `~/.config/<slug>/` into
/// `~/.codans/config[-dev]/` + `~/.codans/state[-dev]/`.
///
/// - Known live files move to their new home (never over an existing file —
///   a collision archives the legacy copy instead).
/// - Litter is deleted: `.DS_Store`, crash-orphaned temp files, zero-byte
///   files, the `sessions.json.lock` sidecar, and the GitHub snapshot cache
///   (its old shape is unreadable to the versioned cache, which refetches).
/// - Everything else — old backups, files no build reads any more — moves
///   into `<state>/backups/legacy-config-<ts>/`, so nothing is lost.
/// - The emptied legacy directory is removed; if something could not be
///   moved, a `MOVED.md` there points at the new roots.
///
/// Runs only when the legacy directory exists and the new state root has no
/// `catalog.json` yet, and never while another process holds the legacy
/// `sessions.json.lock` (an older build still running on the legacy root).
public nonisolated enum LegacyConfigMigrator {
  public enum Destination: Equatable, Sendable {
    case config
    case state
  }

  public struct Report: Equatable, Sendable {
    public var moved: [String: URL] = [:]
    public var archived: [String] = []
    public var deleted: [String] = []
    public var failed: [String] = []
    public var archiveDirectory: URL?
    public var removedLegacyDirectory = false
  }

  public enum Skip: Error, Equatable, Sendable {
    case noLegacyDirectory
    case alreadyMigrated
    case legacyInUse
  }

  /// Live entries and where they go. Directories move whole.
  public static let knownEntries: [String: Destination] = [
    "settings.json": .config,
    "shortcuts.json": .config,
    "master-terminal": .config,
    "catalog.json": .state,
    "sessions.json": .state,
    "notifications.json": .state,
    "notifications.quarantine-shown": .state,
    "remote-hosts.json": .state,
    "saved-server-hosts.json": .state,
    "remote-devices.json": .state,
    "project-icons": .state,
    "agent-homes": .state,
  ]

  /// Entries deleted outright, by name.
  static let litterNames: Set<String> = [".DS_Store", "sessions.json.lock", "github-snapshots.json"]

  static let logger = Logger(subsystem: "com.gumpw.codans.persistence", category: "legacy-migration")

  public static func migrateIfNeeded(
    legacy: URL,
    config: URL,
    state: URL,
    now: Date = Date(),
    fileManager: FileManager = .default
  ) -> Result<Report, Skip> {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return .failure(.noLegacyDirectory)
    }
    guard !fileManager.fileExists(atPath: state.appendingPathComponent("catalog.json").path) else {
      logger.notice("legacy config at \(legacy.path, privacy: .public) left alone: state root already has a catalog")
      return .failure(.alreadyMigrated)
    }
    guard !isLockHeld(legacy.appendingPathComponent("sessions.json.lock")) else {
      logger.notice("legacy config at \(legacy.path, privacy: .public) is in use by another process; not migrating")
      return .failure(.legacyInUse)
    }

    let report = migrate(legacy: legacy, config: config, state: state, now: now, fileManager: fileManager)
    logger.notice(
      "migrated legacy config \(legacy.path, privacy: .public): moved \(report.moved.keys.sorted(), privacy: .public), archived \(report.archived, privacy: .public), deleted \(report.deleted, privacy: .public), failed \(report.failed, privacy: .public)"
    )
    return .success(report)
  }

  static func migrate(legacy: URL, config: URL, state: URL, now: Date, fileManager: FileManager) -> Report {
    var report = Report()
    let names = ((try? fileManager.contentsOfDirectory(atPath: legacy.path)) ?? []).sorted()
    let archiveDirectory = StoreBackup.directory(for: state.appendingPathComponent("_"))
      .appendingPathComponent("legacy-config-\(StoreBackup.timestamp(now))", isDirectory: true)

    func archive(_ name: String, from source: URL) {
      do {
        try fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: archiveDirectory.appendingPathComponent(name))
        report.archived.append(name)
        report.archiveDirectory = archiveDirectory
      } catch {
        report.failed.append(name)
      }
    }

    for name in names {
      let source = legacy.appendingPathComponent(name)
      if isLitter(name, at: source, fileManager: fileManager) {
        if (try? fileManager.removeItem(at: source)) != nil {
          report.deleted.append(name)
        } else {
          report.failed.append(name)
        }
        continue
      }
      guard let destination = knownEntries[name] else {
        archive(name, from: source)
        continue
      }
      let root = destination == .config ? config : state
      let target = root.appendingPathComponent(name)
      if fileManager.fileExists(atPath: target.path) {
        archive(name, from: source)
        continue
      }
      do {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: target)
        report.moved[name] = target
      } catch {
        report.failed.append(name)
      }
    }

    if report.failed.isEmpty, (try? fileManager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true {
      report.removedLegacyDirectory = (try? fileManager.removeItem(at: legacy)) != nil
    }
    if !report.removedLegacyDirectory {
      let note = """
        # Moved

        codans no longer reads this directory. Configuration now lives in
        `\(config.path)` and app state in `\(state.path)`; anything left here
        could not be moved automatically.

        """
      try? Data(note.utf8).write(to: legacy.appendingPathComponent("MOVED.md"))
    }
    return report
  }

  static func isLitter(_ name: String, at url: URL, fileManager: FileManager) -> Bool {
    if litterNames.contains(name) || AtomicFileStore.isTemporaryName(name) { return true }
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      (attributes[.size] as? NSNumber)?.intValue == 0
    else { return false }
    return true
  }

  /// Whether another process holds the `fcntl` write lock `SessionStore`
  /// takes on `sessions.json.lock`.
  static func isLockHeld(_ url: URL) -> Bool {
    let fd = Darwin.open(url.path, O_RDONLY)
    guard fd >= 0 else { return false }
    defer { _ = Darwin.close(fd) }
    var probe = Darwin.flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
    guard Darwin.fcntl(fd, F_GETLK, &probe) == 0 else { return false }
    return probe.l_type != Int16(F_UNLCK)
  }
}
