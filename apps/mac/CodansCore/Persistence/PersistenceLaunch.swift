import Foundation

/// Launch-time housekeeping for the on-disk roots, run once before any store
/// opens a file.
public nonisolated enum PersistenceLaunch {
  /// Moves the pre-split `~/.config/<slug>/` into the new roots (skipped when
  /// either root is overridden — an isolated run owns its directories), then
  /// sweeps crash-orphaned temp files from both roots.
  public static func prepare(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
    fileManager: FileManager = .default
  ) {
    let configOverride = environment[CodansEnvironment.Key.configDirectory.rawValue]
    let stateOverride = environment[CodansEnvironment.Key.stateDirectory.rawValue]
    let config = AppDirectories.configDirectory(home: home, override: configOverride)
    let state = AppDirectories.stateDirectory(home: home, override: stateOverride, configOverride: configOverride)

    if (configOverride ?? "").isEmpty, (stateOverride ?? "").isEmpty {
      _ = LegacyConfigMigrator.migrateIfNeeded(
        legacy: AppDirectories.legacyConfigDirectory(home: home),
        config: config,
        state: state,
        fileManager: fileManager
      )
    }

    for root in Set([config, state]) {
      AtomicFileStore.sweepOrphanedTemporaries(in: root, fileManager: fileManager)
    }
  }
}
