import Foundation
import Testing

@testable import CodansCore

/// Dedicated coverage for the v2 → v3 branch in `SettingsMigration.load`. Round-trips v2
/// fixtures on disk through the fold and asserts the resulting v3 file shape, including
/// the catalog-overrides injection for the two fields (`defaultEditor`,
/// `worktreesDirectory`) that moved off `catalog.json`.
struct SettingsMigrationV2ToV3Tests {
  @Test
  func v2WithRepositoryEntryFoldsIntoProjectsGit() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    let projectUUID = UUID()
    let json = """
      {
        "version": 2,
        "repositories": {
          "\(projectUUID.uuidString)": {
            "defaultMergeStrategy": "squash",
            "githubDisabled": true
          }
        }
      }
      """
    try Data(json.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .migratedFromV2(let settings, let backupURL) = outcome else {
      Issue.record("Expected .migratedFromV2, got \(outcome)")
      return
    }

    let pid = ProjectID(raw: projectUUID)
    let entry = try #require(settings.projects[pid])
    #expect(entry.git?.defaultMergeStrategy == .squash)
    #expect(entry.git?.githubDisabled == true)
    #expect(entry.defaultEditor == nil)
    #expect(entry.worktreesDirectory == nil)
    #expect(settings.version == 3)
    #expect(backupURL.lastPathComponent.hasPrefix("settings.json.v2-"))
    #expect(FileManager.default.fileExists(atPath: backupURL.path))
    // Atomic migration committed the v3 file too.
    let readBack = try #require(try AtomicFileStore.read(Settings.self, at: harness.fileURL))
    #expect(readBack == settings)
  }

  @Test
  func v2FoldsCatalogOverridesIntoTopLevelFields() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    let projectUUID = UUID()
    let json = """
      {
        "version": 2,
        "repositories": {
          "\(projectUUID.uuidString)": {
            "defaultMergeStrategy": "rebase"
          }
        }
      }
      """
    try Data(json.utf8).write(to: harness.fileURL)

    let pid = ProjectID(raw: projectUUID)
    let overrides: SettingsMigration.CatalogOverrides = [
      pid: (defaultEditor: "vscode", worktreesDirectory: "/Users/x/wt/a")
    ]

    let outcome = try SettingsMigration.load(
      from: harness.fileURL,
      clock: harness.clock,
      catalogOverrides: overrides
    )
    guard case .migratedFromV2(let settings, _) = outcome else {
      Issue.record("Expected .migratedFromV2, got \(outcome)")
      return
    }

    let entry = try #require(settings.projects[pid])
    #expect(entry.defaultEditor == "vscode")
    #expect(entry.worktreesDirectory == "/Users/x/wt/a")
    #expect(entry.git?.defaultMergeStrategy == .rebase)
  }

  @Test
  func v2FoldsCatalogOnlyPidsIntoProjects() throws {
    // Pids that have catalog overrides but NO entry in v2 `repositories` must still
    // surface in v3 `projects` — otherwise a Project that only ever set an editor
    // override (and never used GitHub) would lose the override on first launch.
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    // v2 settings.json has no `repositories` entry for the catalog-only pid.
    let json = #"{"version": 2}"#
    try Data(json.utf8).write(to: harness.fileURL)

    let pid = ProjectID()
    let overrides: SettingsMigration.CatalogOverrides = [
      pid: (defaultEditor: "vscode", worktreesDirectory: nil)
    ]

    let outcome = try SettingsMigration.load(
      from: harness.fileURL,
      clock: harness.clock,
      catalogOverrides: overrides
    )
    guard case .migratedFromV2(let settings, _) = outcome else {
      Issue.record("Expected .migratedFromV2, got \(outcome)")
      return
    }

    let entry = try #require(settings.projects[pid])
    #expect(entry.defaultEditor == "vscode")
    #expect(entry.worktreesDirectory == nil)
    #expect(entry.git == nil, "no GitHub override → no git subtree")
  }

  @Test
  func v2WithoutRepositoriesStillMigratesGeneralSubtree() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    let json = #"""
      {
        "version": 2,
        "general": { "appearance": "dark", "defaultEditorID": "cursor" }
      }
      """#
    try Data(json.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .migratedFromV2(let settings, _) = outcome else {
      Issue.record("Expected .migratedFromV2, got \(outcome)")
      return
    }

    #expect(settings.projects.isEmpty)
    #expect(settings.general.defaultEditorID == "cursor")
    #expect(settings.general.appearance == .dark)
  }

  @Test
  func v2WithUnparseableRepositoryKeyDropsEntry() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    let json = """
      {
        "version": 2,
        "repositories": {
          "not-a-uuid": { "defaultMergeStrategy": "squash" }
        }
      }
      """
    try Data(json.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .migratedFromV2(let settings, _) = outcome else {
      Issue.record("Expected .migratedFromV2, got \(outcome)")
      return
    }
    #expect(settings.projects.isEmpty)
  }

  @Test
  func v3FilePassesThroughUnmodifiedAfterV2MigrationRoundTrip() throws {
    // Running migration a second time against the v3 file produced by a first run must
    // be a no-op (`.v3`) — proves idempotence.
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    let projectUUID = UUID()
    let seed = """
      {
        "version": 2,
        "repositories": {
          "\(projectUUID.uuidString)": { "defaultMergeStrategy": "squash" }
        }
      }
      """
    try Data(seed.utf8).write(to: harness.fileURL)

    // First load: v2 → v3 migration.
    let first = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .migratedFromV2 = first else {
      Issue.record("Expected .migratedFromV2, got \(first)")
      return
    }

    // Second load: strict v3 pass-through.
    let second = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .v3 = second else {
      Issue.record("Expected .v3 on second load, got \(second)")
      return
    }
  }
}

// MARK: - Harness

private final class MigrationHarness {
  let directory: URL
  var fileURL: URL { directory.appendingPathComponent("settings.json", isDirectory: false) }
  let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_777_190_400) }

  init() {
    self.directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SettingsMigrationV2ToV3Tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}
