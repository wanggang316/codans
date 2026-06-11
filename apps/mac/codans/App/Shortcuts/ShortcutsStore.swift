import Foundation
import Observation
import CodansCore
import os.log

/// `@MainActor @Observable` owner of `~/.config/codans/shortcuts.json`. Single writer
/// for the file. Mirrors `SettingsStore`'s lifecycle — atomic-rename writes through
/// `AtomicFileStore`, 500 ms trailing debounce on mutations, broken-file backup on decode
/// failure.
///
/// `overrides` is the persisted document; `resolved` is the schema-overlay snapshot. Both
/// recompute together: every mutation re-runs `ShortcutResolver.resolve` so SwiftUI's
/// `@Observable` change-tracking publishes both views in a single tick.
///
/// On version mismatch or unparseable JSON the broken file is moved aside as
/// `shortcuts.json.broken-<yyyyMMdd-HHmmss>` and the in-memory store starts empty. The
/// store still persists subsequently — unlike `SettingsStore`'s strict v2/v3 migration the
/// shortcuts file has no data to preserve across an unsupported version: a fresh user
/// override layer is the safest recovery.
@MainActor
@Observable
final class ShortcutsStore {
  private(set) var overrides: ShortcutOverrideStore
  private(set) var resolved: ResolvedShortcutMap

  private let fileURL: URL
  private let logger = Logger(subsystem: "com.gumpw.codans.persistence", category: "shortcuts")
  @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?
  @ObservationIgnored private let debounceWindow: Duration

  /// Production debounce window between a mutation and the atomic-rename write. Matches
  /// `SettingsStore`. Tests inject a shorter window.
  static let debounceWindow: Duration = .milliseconds(500)

  init(
    fileURL: URL = ShortcutsStore.defaultURL(),
    debounceWindow: Duration = ShortcutsStore.debounceWindow
  ) {
    self.fileURL = fileURL
    self.debounceWindow = debounceWindow

    let loaded = Self.loadOrRecover(fileURL: fileURL, logger: logger)
    self.overrides = loaded
    self.resolved = ShortcutResolver.resolve(overrides: loaded)
  }

  deinit {
    pendingSaveTask?.cancel()
  }

  /// On-disk location: `<AppDirectories.configDirectory>/shortcuts.json`
  /// (`-dev` suffixed for Debug builds — see `AppDirectories`).
  static func defaultURL(
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> URL {
    AppDirectories.configDirectory(home: home)
      .appendingPathComponent("shortcuts.json", isDirectory: false)
  }

  // MARK: - Mutations

  /// Replace the override for `id`. Caller is responsible for conflict resolution; the store
  /// does not run conflict detection on its own.
  ///
  /// When the supplied binding is byte-equal to the schema default, the override is dropped
  /// instead of stored — the persisted file stays slim and the Settings pane's "Custom"
  /// pill / reset glyph stay consistent with the user's intent (a deliberate revert to
  /// default lands on `.schemaDefault` source rather than a no-op `.userOverride`).
  func update(_ id: CommandID, to binding: ShortcutBinding) {
    let schemaDefault = ShortcutSchema.app.entry(for: id)?.defaultBinding
    if let schemaDefault, binding == schemaDefault {
      clear(id)
      return
    }
    overrides.overrides[id] = binding
    rebuildResolved()
    scheduleSave()
  }

  /// Atomically disable one shortcut and assign a new binding to another. Used by the
  /// settings pane when the user opts to replace a conflicting binding. Coalesces both
  /// mutations into a single resolved-map rebuild and a single debounced save so observers
  /// never see the intermediate "both disabled / both unbound" state.
  func resolveConflict(disabling conflicting: CommandID, assigning target: CommandID, to binding: ShortcutBinding) {
    if let existing = overrides.overrides[conflicting] ?? ShortcutSchema.app.entry(for: conflicting)?.defaultBinding {
      overrides.overrides[conflicting] = ShortcutBinding(
        keyCode: existing.keyCode,
        modifiers: existing.modifiers,
        isEnabled: false
      )
    }
    let schemaDefault = ShortcutSchema.app.entry(for: target)?.defaultBinding
    if let schemaDefault, binding == schemaDefault {
      overrides.overrides.removeValue(forKey: target)
    } else {
      overrides.overrides[target] = binding
    }
    rebuildResolved()
    scheduleSave()
  }

  /// Mark `id` as user-disabled. Preserves the keyCode/modifiers of whatever binding was in
  /// effect (override if present, else schema default) and flips `isEnabled` to false.
  func disable(_ id: CommandID) {
    let baseBinding =
      overrides.overrides[id]
      ?? ShortcutSchema.app.entry(for: id)?.defaultBinding
    guard let baseBinding else { return }
    let disabled = ShortcutBinding(
      keyCode: baseBinding.keyCode,
      modifiers: baseBinding.modifiers,
      isEnabled: false
    )
    overrides.overrides[id] = disabled
    rebuildResolved()
    scheduleSave()
  }

  /// Drop the override for `id`. The schema default re-applies; if the result still
  /// collides with another command's user override, the caller should run
  /// `ShortcutResetPlanner.plan` first and route through `applyResetPlan`.
  func clear(_ id: CommandID) {
    guard overrides.overrides[id] != nil else { return }
    overrides.overrides.removeValue(forKey: id)
    rebuildResolved()
    scheduleSave()
  }

  /// Drop every override. The resolved map collapses to schema defaults.
  func resetAll() {
    guard !overrides.overrides.isEmpty else { return }
    overrides.overrides.removeAll()
    rebuildResolved()
    scheduleSave()
  }

  /// Apply a `ShortcutResetPlanner` plan: drop the target's override plus any cascaded
  /// resets in one mutation. Equivalent to calling `clear` for each ID but with one
  /// `scheduleSave` and one resolved-map rebuild.
  func applyResetPlan(_ plan: ShortcutResetPlan) {
    overrides.overrides.removeValue(forKey: plan.target)
    for id in plan.cascadingResets {
      overrides.overrides.removeValue(forKey: id)
    }
    rebuildResolved()
    scheduleSave()
  }

  // MARK: - Persistence

  /// Cancels any pending debounced write and flushes immediately. Callers:
  /// `applicationWillTerminate`, explicit user save, test teardown.
  func flush() {
    do {
      try saveNow()
    } catch {
      logger.error("Failed to flush shortcuts: \(String(describing: error), privacy: .public)")
    }
  }

  func saveNow() throws {
    pendingSaveTask?.cancel()
    pendingSaveTask = nil
    try AtomicFileStore.write(overrides, to: fileURL)
  }

  private func scheduleSave() {
    pendingSaveTask?.cancel()
    let snapshot = overrides
    pendingSaveTask = Task { [weak self] in
      let window = self?.debounceWindow ?? Self.debounceWindow
      try? await Task.sleep(for: window)
      // Re-check cancellation after the sleep so a `flush()` / `saveNow()` that fired
      // during the debounce window cannot be raced by this task's stale snapshot.
      guard !Task.isCancelled else { return }
      guard let self else { return }
      do {
        try AtomicFileStore.write(snapshot, to: self.fileURL)
      } catch {
        self.logger.error(
          "Failed to save shortcuts: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  private func rebuildResolved() {
    resolved = ShortcutResolver.resolve(overrides: overrides)
  }

  // MARK: - Load / recovery

  private static func loadOrRecover(
    fileURL: URL,
    logger: Logger
  ) -> ShortcutOverrideStore {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }

    do {
      let decoded = try AtomicFileStore.read(ShortcutOverrideStore.self, at: fileURL)
      guard let store = decoded else { return .empty }
      if store.version != ShortcutOverrideStore.currentVersion {
        moveAside(
          fileURL,
          reason: "unsupported version \(store.version)",
          fileManager: fileManager,
          logger: logger
        )
        return .empty
      }
      return store
    } catch {
      logger.error(
        "shortcuts.json was unparseable: \(String(describing: error), privacy: .public); starting empty"
      )
      moveAside(fileURL, reason: "decode failed", fileManager: fileManager, logger: logger)
      return .empty
    }
  }

  private static func moveAside(
    _ url: URL,
    reason: String,
    fileManager: FileManager,
    logger: Logger
  ) {
    let backup = url.deletingLastPathComponent()
      .appendingPathComponent(
        "\(url.lastPathComponent).broken-\(filesystemSafeTimestamp(.now))",
        isDirectory: false
      )
    do {
      try fileManager.moveItem(at: url, to: backup)
      logger.info(
        "Backed up unreadable shortcuts.json (\(reason, privacy: .public)) to \(backup.lastPathComponent, privacy: .public)"
      )
    } catch {
      logger.error(
        "Failed to back up unreadable shortcuts.json (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)"
      )
    }
  }

  private static func filesystemSafeTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
  }
}
