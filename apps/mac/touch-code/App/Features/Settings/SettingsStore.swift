import Foundation
import Observation
import TouchCodeCore
import os.log

/// `@MainActor @Observable` owner of `~/.config/touch-code/settings.json` (v3). Single writer
/// for the file. Mirrors the `CatalogStore` pattern: atomic-rename writes via
/// `AtomicFileStore`, 500 ms trailing debounce on structural mutations, broken-file backup
/// on decode failure. On first launch after a schema transition, the pre-current
/// `settings.json` is routed through `SettingsMigration.load` and its original is preserved
/// as `settings.json.v{N}-<ts>`.
///
/// Mutations go through section-scoped `mutate*` closures or the editor-specific
/// convenience methods; direct property assignment is not exposed. Views subscribe through
/// the `@Observable` surface.
@MainActor
@Observable
final class SettingsStore {
  private(set) var settings: Settings

  private let fileURL: URL
  private let logger = Logger(subsystem: "com.touch-code.persistence", category: "settings")
  @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?
  @ObservationIgnored private let debounceWindow: Duration
  /// `false` when migration returned `.migrationBackupFailed` — the original settings.json
  /// is still at the canonical URL and must not be overwritten. In this state all mutate
  /// APIs still work in-memory but `scheduleSave` / `saveNow` / `flush` become no-ops.
  @ObservationIgnored private var persistenceEnabled: Bool = true

  /// Production debounce window between a mutation and the atomic-rename write. Matches
  /// `CatalogStore`. Tests inject a shorter window via the initializer.
  static let debounceWindow: Duration = .milliseconds(500)

  init(
    fileURL: URL = Settings.defaultURL(),
    debounceWindow: Duration = SettingsStore.debounceWindow,
    knownEditorIDs: Set<EditorID> = Set(EditorRegistry.registry.map(\.id)),
    catalogOverrides: SettingsMigration.CatalogOverrides = [:]
  ) {
    self.fileURL = fileURL
    self.debounceWindow = debounceWindow
    // `migrationSafeToPersist` gates every subsequent save attempt. When the migration
    // helper returns `.migrationBackupFailed`, the original v1/v2 file may still be sitting
    // at the canonical URL — writing on top of it would destroy the user's historical data.
    // Setting the flag to false puts the store into a read-only / in-memory-only mode.
    var safeToPersist = true
    var needsSeedPersist = false

    do {
      switch try SettingsMigration.load(from: fileURL, catalogOverrides: catalogOverrides) {
      case .fresh:
        // First launch with no settings.json yet. When the catalog side has legacy v1
        // overrides (drained from catalog.json before this init), we must seed the
        // fresh settings tree with those values — otherwise the catalog v2 save that
        // follows has already stripped the only copy and the user's editor /
        // worktree-dir overrides vanish silently. Empty map = nothing to do.
        var fresh = Settings.default
        for (pid, overrides) in catalogOverrides {
          fresh.projects[pid] = ProjectSettings(
            defaultEditor: overrides.defaultEditor,
            worktreesDirectory: overrides.worktreesDirectory
          )
        }
        self.settings = fresh
        needsSeedPersist = !catalogOverrides.isEmpty
      case .v3(let existing):
        self.settings = existing
      case .migratedFromV1(_, let backupURL), .migratedFromV2(_, let backupURL):
        // Migration already committed both the new canonical file and the backup durably —
        // we just read the migrated tree back from disk so the in-memory copy matches what
        // the next launch will see.
        let persisted = (try? AtomicFileStore.read(Settings.self, at: fileURL)) ?? nil
        if let persisted {
          self.settings = persisted
          logger.info("Loaded migrated settings.json (backup: \(backupURL.lastPathComponent, privacy: .public))")
        } else {
          // Extraordinarily unlikely: migration claimed success but the file isn't readable.
          // Treat as unsafe — don't overwrite whatever IS on disk.
          logger.error("Migration reported success but settings.json is not readable; refusing to persist")
          self.settings = .default
          safeToPersist = false
        }
      case .unsupported(let version, let backupURL):
        logger.error(
          "settings.json had unsupported version \(version, privacy: .public); starting defaults (backup: \(backupURL.lastPathComponent, privacy: .public))"
        )
        self.settings = .default
      case .corrupt(let backupURL):
        logger.error(
          "settings.json was unparseable; starting defaults (backup: \(backupURL.lastPathComponent, privacy: .public))"
        )
        self.settings = .default
      case .migrationBackupFailed(let description):
        // The original file is still at the canonical URL (or was restored there). Do NOT
        // persist anything on top of it — the user's data is intact and takes precedence
        // over the in-memory defaults until a human intervenes.
        logger.error(
          "settings.json migration could not preserve original atomically: \(description, privacy: .public); starting defaults in read-only mode"
        )
        self.settings = .default
        safeToPersist = false
      }
    } catch {
      logger.error(
        "SettingsMigration.load failed with \(String(describing: error), privacy: .public); starting defaults in read-only mode"
      )
      self.settings = .default
      safeToPersist = false
    }
    self.persistenceEnabled = safeToPersist

    // When we seeded `.fresh` from catalog overrides, persist immediately — the next
    // launch would find a v2 catalog already on disk (drain empty) and settings.json
    // still missing (.fresh again with no seed), permanently losing the overrides.
    if needsSeedPersist {
      scheduleSave()
    }

    // C8a Phase 5 M1 — reset any stored `general.defaultEditorID` that is not in the
    // current built-in registry. Stale IDs come from the retired C8 `customEditors`
    // feature; the resolver would silently fall back, but leaving the dead value on disk
    // misreports the user's actual preference. Run after the switch so every decode
    // branch (including `.default`) is covered; idempotent.
    let didNormalize = settings.garbageCollectEditors(knownIDs: knownEditorIDs)
    if didNormalize {
      logger.info("Reset stale general.defaultEditorID not in built-in registry")
      // Persist the cleaned value so the normalization sticks across launches. Uses the
      // standard debounced save pipeline; no-op when persistence is disabled.
      scheduleSave()
    }
  }

  // MARK: - Section mutators

  func mutateGeneral(_ transform: (inout GeneralSettings) -> Void) {
    transform(&settings.general)
    scheduleSave()
  }

  func mutateDeveloper(_ transform: (inout DeveloperSettings) -> Void) {
    transform(&settings.developer)
    scheduleSave()
  }

  func mutateWorktree(_ transform: (inout WorktreeSettings) -> Void) {
    transform(&settings.worktree)
    scheduleSave()
  }

  func mutateNotifications(_ transform: (inout NotificationsSettings) -> Void) {
    transform(&settings.notifications)
    scheduleSave()
  }

  /// Mutates the `ProjectSettings` for `projectID`, creating an empty entry if none
  /// exists. The pre-save garbage collection in `scheduleSave` drops any entry that ends up
  /// effectively empty so `settings.json` never accumulates useless `{}` objects, and also
  /// collapses `projects[pid].git` to `nil` when the nested subtree is at defaults.
  func mutateProject(
    _ projectID: ProjectID,
    _ transform: (inout ProjectSettings) -> Void
  ) {
    var entry = settings.projects[projectID] ?? ProjectSettings()
    transform(&entry)
    settings.projects[projectID] = entry
    scheduleSave()
  }

  // MARK: - Editor convenience (legacy surface kept for SettingsWriter)

  func setDefaultEditorID(_ id: EditorID?) {
    settings.general.defaultEditorID = id
    scheduleSave()
  }

  func setDefaultGitViewerID(_ id: EditorID?) {
    settings.general.defaultGitViewerID = id
    scheduleSave()
  }

  func setAppearance(_ appearance: AppearancePreference) {
    settings.general.appearance = appearance
    scheduleSave()
  }

  /// Persist the user's "Confirm before quitting" preference. `applicationShouldTerminate`
  /// reads this to decide whether to present the quit confirmation dialog at all.
  func setQuitConfirmation(_ value: QuitConfirmation) {
    settings.general.quitConfirmation = value
    scheduleSave()
  }

  /// Persist the user's "On quit" action. Applied directly when the confirmation dialog is
  /// skipped, and drives the default-focused button when the dialog IS shown.
  func setQuitAction(_ value: QuitAction) {
    settings.general.quitAction = value
    scheduleSave()
  }

  // MARK: - Updates (Sparkle preferences mirrored in settings.json)

  func setUpdateChannel(_ channel: UpdateChannel) {
    settings.general.updateChannel = channel
    scheduleSave()
  }

  func setUpdateCheckInterval(_ interval: UpdateCheckInterval) {
    settings.general.updateCheckInterval = interval
    scheduleSave()
  }

  func setUpdatesAutomaticallyCheckForUpdates(_ enabled: Bool) {
    settings.general.updatesAutomaticallyCheckForUpdates = enabled
    scheduleSave()
  }

  func setUpdatesAutomaticallyDownloadUpdates(_ enabled: Bool) {
    settings.general.updatesAutomaticallyDownloadUpdates = enabled
    scheduleSave()
  }

  // C8a Phase 3 retired the custom-editor surface. `addCustomEditor` / `updateCustomEditor`
  // / `removeCustomEditor` are gone; the `customEditors` field was removed from
  // `GeneralSettings`. Phase 4a's Settings pane uses the built-in registry exclusively.

  /// Hard-overwrite the entire settings document. Only used by tests and recovery paths.
  func replaceAll(_ new: Settings) {
    settings = new
    scheduleSave()
  }

  // MARK: - Persistence

  func saveNow() throws {
    guard persistenceEnabled else {
      logger.error("saveNow skipped: persistence disabled (migration did not complete atomically)")
      return
    }
    // Cancel any pending debounced save BEFORE writing so the in-flight task can't clobber
    // us with a stale snapshot after this call returns. Matches PR #22 review N6.
    pendingSaveTask?.cancel()
    pendingSaveTask = nil
    settings.garbageCollect()
    try AtomicFileStore.write(settings, to: fileURL)
  }

  /// Cancels any pending debounced write and flushes immediately. Callers:
  /// `applicationWillTerminate`, explicit user Save, test teardown.
  func flush() {
    do {
      try saveNow()
    } catch {
      logger.error("Failed to flush settings: \(String(describing: error), privacy: .public)")
    }
  }

  private func scheduleSave() {
    guard persistenceEnabled else {
      logger.debug("scheduleSave skipped: persistence disabled (migration did not complete atomically)")
      return
    }
    pendingSaveTask?.cancel()
    var snapshot = settings
    snapshot.garbageCollect()
    pendingSaveTask = Task { [weak self] in
      let window = self?.debounceWindow ?? Self.debounceWindow
      try? await Task.sleep(for: window)
      guard !Task.isCancelled else { return }
      guard let self else { return }
      do {
        try AtomicFileStore.write(snapshot, to: self.fileURL)
      } catch {
        // Log and leave the existing file untouched. Transient disk-full / permissions flips
        // shouldn't cost the user their persisted settings; the next successful save picks up
        // the in-memory snapshot. Only the load path moves corrupt files aside.
        self.logger.error("Failed to save settings: \(String(describing: error), privacy: .public)")
      }
    }
  }
}
