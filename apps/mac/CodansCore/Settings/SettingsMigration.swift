import Foundation
import os.log

/// Entry point for loading `settings.json`: tries v2 first, falls back to v1 with a
/// permissive legacy decode, backs aside anything that can neither be parsed nor recognised.
/// `SettingsStore` delegates its initial load through `SettingsMigration.load`.
///
/// ## Atomicity invariant
///
/// Data safety on the migration path is critical: a crash or partial failure must never
/// destroy the user's historical settings without producing a recoverable backup. The legacy
/// migration branch uses the sequence below, executed inside `load` so the caller can treat
/// `.migratedFromV1` as "both files durably on disk, caller need not write anything":
///
/// 1. Encode the migrated v2 tree and write it through `AtomicFileStore.write` to a
///    sibling temp URL (`<settings>.new-<uuid>`) — fsync inside AtomicFileStore means
///    the temp is durable before the next step runs.
/// 2. `rename(2)` the original v1 file to `settings.json.v1-<yyyyMMdd-HHmmss>`. After this
///    returns the backup has committed; the original path is empty.
/// 3. `rename(2)` the temp into the original path. The v2 file is durable at the
///    canonical URL, the backup at `.v1-<ts>`.
///
/// Failure handling per step:
/// - Step 1 fails → no changes on disk; `.migrationBackupFailed` returned.
/// - Step 2 fails → delete the temp, original still canonical; `.migrationBackupFailed`.
/// - Step 3 fails → attempt to restore the original by renaming the backup back; delete
///   the temp; `.migrationBackupFailed`.
///
/// The brief interval between step 2 and step 3 is the only window where the canonical
/// path is missing. A crash there leaves the durable backup — the next launch sees a
/// fresh file and the user can recover from `.v1-<ts>` manually.
public nonisolated enum SettingsMigration {
  public enum LoadOutcome: Equatable {
    /// File did not exist on disk; caller starts from defaults.
    case fresh
    /// File decoded as current-version v3; no migration required.
    case v3(Settings)
    /// File decoded under the permissive v1 shape; caller already sees the v3 tree on
    /// disk at the canonical URL, and the original v1 content is preserved at `backupURL`.
    /// Caller must NOT call `AtomicFileStore.write` again — both writes already landed.
    case migratedFromV1(Settings, backupURL: URL)
    /// File decoded as the v2 shape (`repositories: [ProjectID: RepositorySettings]`);
    /// the in-memory tree has been lifted to v3 with every `repositories[pid]`'s three
    /// GitHub fields folded into `projects[pid].git.*` and any catalog-side
    /// `defaultEditor` / `worktreesDirectory` supplied by the injected
    /// `catalogOverrides` closure folded into `projects[pid]` top-level fields. Caller
    /// already sees the v3 tree on disk; the original v2 content is at `backupURL`.
    case migratedFromV2(Settings, backupURL: URL)
    /// File carried an unrecognised `version` number. Original renamed to
    /// `settings.json.broken-<yyyyMMdd-HHmmss>`; caller starts from defaults.
    case unsupported(Int, backupURL: URL)
    /// File was present but unparseable (not v3 shape, not legacy v1/v2 shape). Original
    /// renamed to `settings.json.broken-<yyyyMMdd-HHmmss>`; caller starts from defaults.
    case corrupt(backupURL: URL)
    /// Migration attempted but the atomic sequence could not complete. The user's original
    /// v1 or v2 file is still at the canonical URL (or restored there) — no data was
    /// destroyed. Caller should start from defaults, log prominently, and MUST NOT persist
    /// anything on top of the canonical URL; doing so would overwrite the still-intact
    /// historical data.
    case migrationBackupFailed(description: String)
  }

  /// Logger category used by the migration path. Distinct from `"settings"` so traces can be
  /// filtered — `log stream --predicate 'subsystem == "com.gumpw.codans.persistence" && category == "migration"'`.
  public static let logger = Logger(subsystem: "com.gumpw.codans.persistence", category: "migration")

  /// Per-Project override map handed in by the caller during the v2→v3 migration. Keys
  /// are the ProjectIDs the catalog still carries `defaultEditor` / `worktreesDirectory`
  /// values for at first-launch time; values are the captured fields. Empty by default
  /// (tests + post-migration launches that hit the v3 fast path).
  public typealias CatalogOverrides = [ProjectID: (defaultEditor: EditorID?, worktreesDirectory: String?)]

  /// Load the settings file at `url` and return how it was handled. Side effects: if a
  /// backup is produced OR a migrated v3 file is installed, disk state is updated before
  /// the function returns. `clock` supplies the timestamp used in backup filenames —
  /// injected for test determinism. `catalogOverrides` is consulted during the v2→v3
  /// migration branch to fold `Project.defaultEditor` / `Project.worktreesDirectory`
  /// stripped from the companion catalog.json into `projects[pid]`. Empty map by default
  /// (tests + post-migration launches).
  public static func load(
    from url: URL,
    fileManager: FileManager = .default,
    clock: @Sendable () -> Date = { Date() },
    catalogOverrides: CatalogOverrides = [:]
  ) throws -> LoadOutcome {
    guard fileManager.fileExists(atPath: url.path) else { return .fresh }

    let data = try Data(contentsOf: url)

    // v3 first — the common case once migration has run.
    do {
      let settings = try JSONDecoder.touchCodeDefault.decode(Settings.self, from: data)
      return .v3(settings)
    } catch Settings.DecodingIssue.unsupportedVersion(let version) where version == 2 {
      // v2 → v3 fold path. Delegate to the dedicated helper so the 3-step atomic rename
      // dance stays readable alongside the v1→v2 variant below.
      return performV2Migration(
        url: url,
        data: data,
        catalogOverrides: catalogOverrides,
        now: clock(),
        fileManager: fileManager
      )
    } catch Settings.DecodingIssue.unsupportedVersion(let version) where version != 1 {
      switch moveAside(url: url, prefix: "settings.json.broken-", at: clock(), fileManager: fileManager) {
      case .success(let backup):
        logger.error(
          "Unsupported settings.json version \(version, privacy: .public); backed up to \(backup.lastPathComponent, privacy: .public)"
        )
        return .unsupported(version, backupURL: backup)
      case .failure(let error):
        logger.error("Unsupported version and backup move failed: \(String(describing: error), privacy: .public)")
        return .migrationBackupFailed(description: "moveAside failed for unsupported version: \(error)")
      }
    } catch {
      // Fall through to legacy decode — a version:1 file throws `unsupportedVersion(1)` here.
    }

    // Legacy v1 shape — permissive. Historical writers both wrote `version: 1`; the helper
    // accepts even a missing `version` field so a crash mid-write during the pre-v2 era
    // still decodes. Catalog overrides are folded into `projects` — users on the double-
    // legacy path (v1 settings + v1 catalog) must not lose per-Project editor /
    // worktrees-directory overrides.
    do {
      let legacy = try JSONDecoder.touchCodeDefault.decode(LegacyV1Settings.self, from: data)
      var migrated = migrate(legacy)
      for (pid, overrides) in catalogOverrides {
        migrated.projects[pid] = ProjectSettings(
          defaultEditor: overrides.defaultEditor,
          worktreesDirectory: overrides.worktreesDirectory
        )
      }
      return performV1Migration(
        url: url,
        migrated: migrated,
        now: clock(),
        fileManager: fileManager
      )
    } catch {
      switch moveAside(url: url, prefix: "settings.json.broken-", at: clock(), fileManager: fileManager) {
      case .success(let backup):
        logger.error(
          "Could not parse settings.json at all; backed up to \(backup.lastPathComponent, privacy: .public). Error: \(String(describing: error), privacy: .public)"
        )
        return .corrupt(backupURL: backup)
      case .failure(let moveError):
        logger.error(
          "Unparseable settings.json and backup move failed: \(String(describing: moveError), privacy: .public)")
        return .migrationBackupFailed(description: "moveAside failed for corrupt JSON: \(moveError)")
      }
    }
  }

  /// Pure mapping from the legacy permissive struct to a v2 Settings tree. Fields absent in
  /// the legacy object fall through to v2 defaults. Exposed independently so tests don't have
  /// to round-trip through the filesystem.
  public static func migrate(_ legacy: LegacyV1Settings) -> Settings {
    var general = GeneralSettings.default
    general.defaultEditorID = legacy.defaultEditorID
    // Legacy `customEditors` array is ignored on migration — see GeneralSettings.

    return Settings(
      version: Settings.currentVersion,
      general: general,
      developer: .default,
      projects: [:]
    )
  }

  /// Parses a v2 `settings.json` payload and lifts it into a v3 `Settings`, then commits
  /// the upgraded shape to disk with the same atomic rename sequence used for v1→v2.
  /// Catalog-side per-Project overrides (the `defaultEditor` and `worktreesDirectory`
  /// fields that lived on `Project` in catalog.json v1) are folded in via the injected
  /// map. Both the intersection (pids in v2 `repositories` ∩ catalog) AND pids only in
  /// the catalog are written out — a user whose Project never had a GitHub override but
  /// did have an editor override would otherwise lose the editor on first launch under
  /// v3. Unparseable `repositories` keys are dropped with a log line.
  private static func performV2Migration(
    url: URL,
    data: Data,
    catalogOverrides: CatalogOverrides,
    now: Date,
    fileManager: FileManager
  ) -> LoadOutcome {
    let legacy: LegacyV2Settings
    do {
      legacy = try JSONDecoder.touchCodeDefault.decode(LegacyV2Settings.self, from: data)
    } catch {
      // A malformed v2 body (declared version:2 but shape is broken) is treated as
      // corrupt — back aside and start from defaults. Matches the v1 corrupt branch.
      switch moveAside(url: url, prefix: "settings.json.broken-", at: now, fileManager: fileManager) {
      case .success(let backup):
        logger.error(
          "Declared version:2 settings.json was unparseable under the v2 shape; backed up to \(backup.lastPathComponent, privacy: .public). Error: \(String(describing: error), privacy: .public)"
        )
        return .corrupt(backupURL: backup)
      case .failure(let moveError):
        return .migrationBackupFailed(description: "moveAside failed for unparseable v2: \(moveError)")
      }
    }

    // Pass 1: every v2 repositories[pid] → projects[pid] with the three GitHub fields
    // folded into `git`. Catalog overrides for the same pid (if any) populate the
    // top-level `defaultEditor` / `worktreesDirectory` fields.
    var projects: [ProjectID: ProjectSettings] = [:]
    for (stringKey, legacyRepo) in legacy.repositories {
      guard let uuid = UUID(uuidString: stringKey) else {
        logger.warning("Dropping unparseable v2 repositories key during migration: \(stringKey, privacy: .public)")
        continue
      }
      let pid = ProjectID(raw: uuid)
      var entry = ProjectSettings(
        git: GitProjectSettings(
          defaultMergeStrategy: legacyRepo.defaultMergeStrategy,
          postMergeAction: legacyRepo.postMergeAction,
          githubDisabled: legacyRepo.githubDisabled
        )
      )
      entry.collapseEmptyGit()
      if let overrides = catalogOverrides[pid] {
        entry.defaultEditor = overrides.defaultEditor
        entry.worktreesDirectory = overrides.worktreesDirectory
      }
      projects[pid] = entry
    }
    // Pass 2: catalog overrides for pids that had no v2 settings entry. Without this
    // pass an editor-only override on a Project that never used GitHub would be
    // dropped silently.
    for (pid, overrides) in catalogOverrides where projects[pid] == nil {
      projects[pid] = ProjectSettings(
        defaultEditor: overrides.defaultEditor,
        worktreesDirectory: overrides.worktreesDirectory
      )
    }

    let migrated = Settings(
      version: Settings.currentVersion,
      general: legacy.general ?? .default,
      developer: legacy.developer ?? .default,
      projects: projects
    )

    return performAtomicMigration(
      url: url,
      migrated: migrated,
      backupPrefix: "settings.json.v2-",
      outcome: { .migratedFromV2(migrated, backupURL: $0) },
      now: now,
      fileManager: fileManager
    )
  }

  // MARK: - Private helpers

  /// Runs the v1 → v3 atomic migration sequence. v1 → v3 skips v2 entirely; v1 files
  /// never had a `repositories` dict so the fold is trivially empty.
  private static func performV1Migration(
    url: URL,
    migrated: Settings,
    now: Date,
    fileManager: FileManager
  ) -> LoadOutcome {
    performAtomicMigration(
      url: url,
      migrated: migrated,
      backupPrefix: "settings.json.v1-",
      outcome: { .migratedFromV1(migrated, backupURL: $0) },
      now: now,
      fileManager: fileManager
    )
  }

  /// Shared 3-step rename dance for every "original shape detected, v3 ready" migration.
  /// Parameterised on `backupPrefix` so v1 backups land at `settings.json.v1-<ts>` and
  /// v2 backups at `settings.json.v2-<ts>`, and on `outcome` so each caller can return
  /// its own `LoadOutcome` variant on success. Returns `.migrationBackupFailed` on any
  /// step error; the user's original file is preserved (restored to the canonical URL
  /// on step 3 failure, still at the canonical URL on step 1/2 failure). Callers on the
  /// failure path must not overwrite the canonical URL.
  private static func performAtomicMigration(
    url: URL,
    migrated: Settings,
    backupPrefix: String,
    outcome: (URL) -> LoadOutcome,
    now: Date,
    fileManager: FileManager
  ) -> LoadOutcome {
    let timestamp = filesystemSafeTimestamp(now)
    let backupURL = url.deletingLastPathComponent()
      .appendingPathComponent("\(backupPrefix)\(timestamp)", isDirectory: false)
    let tempURL = url.deletingLastPathComponent()
      .appendingPathComponent(".settings.json.new-\(UUID().uuidString)", isDirectory: false)

    // Step 1 — encode + fsync migrated v3 into a sibling temp file. AtomicFileStore uses
    // its own write-and-fsync pattern so the contents are durably on disk when this returns.
    do {
      try AtomicFileStore.write(migrated, to: tempURL)
    } catch {
      logger.error("Migration step 1 (write-to-temp) failed: \(String(describing: error), privacy: .public)")
      return .migrationBackupFailed(description: "write-to-temp failed: \(error)")
    }

    // Step 2 — rename original → backup. After this succeeds the old content is durably
    // preserved; the canonical path is empty for a brief moment.
    do {
      try fileManager.moveItem(at: url, to: backupURL)
    } catch {
      try? fileManager.removeItem(at: tempURL)
      logger.error(
        "Migration step 2 (rename-original-to-backup) failed: \(String(describing: error), privacy: .public)")
      return .migrationBackupFailed(description: "rename to backup failed: \(error)")
    }

    // Step 3 — rename temp → canonical. On failure, try to undo step 2 so the user sees
    // the original at the canonical URL again; either way, surface the failure to the
    // caller.
    do {
      try fileManager.moveItem(at: tempURL, to: url)
    } catch {
      logger.error("Migration step 3 (rename-temp-to-canonical) failed: \(String(describing: error), privacy: .public)")
      try? fileManager.moveItem(at: backupURL, to: url)
      try? fileManager.removeItem(at: tempURL)
      return .migrationBackupFailed(description: "rename temp to canonical failed: \(error)")
    }

    logger.info("Migrated settings.json to v3; backup at \(backupURL.lastPathComponent, privacy: .public)")
    return outcome(backupURL)
  }

  /// Non-atomic move of a file to a backup filename. Used for the `unsupported` and
  /// `corrupt` branches where the file is unparseable and the caller wants to clear the
  /// canonical path before starting fresh. Returns `.failure` if the rename fails — the
  /// caller is expected to fall back to `.migrationBackupFailed` rather than clobber the
  /// file on disk.
  private static func moveAside(
    url: URL,
    prefix: String,
    at now: Date,
    fileManager: FileManager
  ) -> Result<URL, Error> {
    let backup = url.deletingLastPathComponent()
      .appendingPathComponent("\(prefix)\(filesystemSafeTimestamp(now))", isDirectory: false)
    do {
      try fileManager.moveItem(at: url, to: backup)
      return .success(backup)
    } catch {
      return .failure(error)
    }
  }

  /// `yyyyMMdd-HHmmss` UTC. Filesystem-safe across case-insensitive and ':'-averse tooling.
  private static func filesystemSafeTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }
}
