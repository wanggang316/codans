import Foundation
import Testing

@testable import CodansCore

struct SettingsMigrationTests {
  @Test
  func missingFileReturnsFresh() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }
    #expect(try SettingsMigration.load(from: harness.fileURL) == .fresh)
  }

  @Test
  func migratesEditorOnlyV1() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    let json = #"""
      {
        "version": 1,
        "defaultEditorID": "vscode",
        "customEditors": [
          { "id": "helix", "displayName": "Helix",
            "template": { "binary": "hx", "args": ["{dir}"] } }
        ]
      }
      """#
    try Data(json.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .migratedFromV1(let settings, let backupURL) = outcome else {
      Issue.record("Expected .migratedFromV1, got \(outcome)")
      return
    }

    #expect(settings.version == Settings.currentVersion)
    #expect(settings.general.defaultEditorID == "vscode")
    // C8a dropped `customEditors`; any legacy entries in the v1 file are ignored on migrate.
    #expect(settings.developer == .default)
    #expect(settings.projects.isEmpty)
    #expect(backupURL.lastPathComponent.hasPrefix("settings.json.v1-"))
    #expect(FileManager.default.fileExists(atPath: backupURL.path))
    // Migration now commits the v2 tree atomically, so the canonical
    // URL must already hold the migrated content when `.migratedFromV1` returns.
    #expect(FileManager.default.fileExists(atPath: harness.fileURL.path))
    let readBack = try #require(try AtomicFileStore.read(Settings.self, at: harness.fileURL))
    #expect(readBack == settings)
  }

  @Test
  func migrationFailureDoesNotDestroyOriginalWhenBackupRenameFails() throws {
    // Simulate a step-2 rename failure by making the parent directory non-writable after
    // the v1 seed lands. moveItem throws, `load` returns `.migrationBackupFailed`, and the
    // canonical URL still holds the user's v1 content.
    let harness = MigrationHarness()
    defer {
      // Re-enable write perms so the cleanup path can remove the dir.
      _ = try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: harness.directory.path
      )
      harness.cleanup()
    }

    let originalJSON = #"{"version":1,"defaultEditorID":"vscode","customEditors":[]}"#
    try Data(originalJSON.utf8).write(to: harness.fileURL)

    // Read-only the parent dir so rename fails.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: harness.directory.path
    )

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    if case .migrationBackupFailed(let description) = outcome {
      #expect(!description.isEmpty)
    } else {
      Issue.record("Expected .migrationBackupFailed, got \(outcome)")
    }

    // Restore write perms so we can inspect.
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: harness.directory.path
    )
    // Original v1 JSON must still be at the canonical URL.
    let still = try String(contentsOf: harness.fileURL, encoding: .utf8)
    #expect(still == originalJSON)
  }

  @Test
  func backsUpUnsupportedVersion() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    try Data(#"{"version":99}"#.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .unsupported(let version, let backupURL) = outcome else {
      Issue.record("Expected .unsupported, got \(outcome)")
      return
    }
    #expect(version == 99)
    #expect(backupURL.lastPathComponent.hasPrefix("settings.json.broken-"))
    #expect(FileManager.default.fileExists(atPath: backupURL.path))
  }

  @Test
  func backsUpCorruptJSON() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    try Data(#"{ broken"#.utf8).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .corrupt(let backupURL) = outcome else {
      Issue.record("Expected .corrupt, got \(outcome)")
      return
    }
    #expect(backupURL.lastPathComponent.hasPrefix("settings.json.broken-"))
    #expect(FileManager.default.fileExists(atPath: backupURL.path))
  }

  @Test
  func v3FilePassesThroughUnmodified() throws {
    let harness = MigrationHarness()
    defer { harness.cleanup() }

    let fixture = Settings(
      version: Settings.currentVersion,
      general: GeneralSettings(defaultEditorID: "cursor"),
      developer: .default,
      projects: [:]
    )
    try JSONEncoder.touchCodeDefault.encode(fixture).write(to: harness.fileURL)

    let outcome = try SettingsMigration.load(from: harness.fileURL, clock: harness.clock)
    guard case .v3(let settings) = outcome else {
      Issue.record("Expected .v3, got \(outcome)")
      return
    }
    #expect(settings == fixture)
    // v3 passthrough must NOT move the original aside.
    #expect(FileManager.default.fileExists(atPath: harness.fileURL.path))
  }
}

// MARK: - Harness

private final class MigrationHarness {
  let directory: URL
  var fileURL: URL { directory.appendingPathComponent("settings.json", isDirectory: false) }
  let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_777_190_400) }  // 2026-04-26

  init() {
    self.directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SettingsMigrationTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}
