import Darwin
import Foundation
import Testing

@testable import CodansCore

struct LegacyConfigMigratorTests {
  private struct Roots {
    let base: URL
    var legacy: URL { base.appendingPathComponent(".config/codans", isDirectory: true) }
    var config: URL { base.appendingPathComponent(".codans/config", isDirectory: true) }
    var state: URL { base.appendingPathComponent(".codans/state", isDirectory: true) }

    func write(_ name: String, _ body: String = "{}", in root: URL? = nil) throws {
      let url = (root ?? legacy).appendingPathComponent(name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(body.utf8).write(to: url)
    }

    func exists(_ path: String, in root: URL) -> Bool {
      FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    func migrate() -> Result<LegacyConfigMigrator.Report, LegacyConfigMigrator.Skip> {
      LegacyConfigMigrator.migrateIfNeeded(
        legacy: legacy, config: config, state: state, now: Date(timeIntervalSince1970: 0))
    }
  }

  private func makeRoots() throws -> Roots {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-migrator-\(UUID().uuidString)", isDirectory: true)
    let roots = Roots(base: base)
    try FileManager.default.createDirectory(at: roots.legacy, withIntermediateDirectories: true)
    return roots
  }

  @Test
  func knownFilesMoveToConfigAndState() throws {
    let roots = try makeRoots()
    defer { try? FileManager.default.removeItem(at: roots.base) }
    try roots.write("settings.json")
    try roots.write("shortcuts.json")
    try roots.write("master-terminal/AGENTS.md", "brief")
    try roots.write("catalog.json")
    try roots.write("sessions.json")
    try roots.write("notifications.json")
    try roots.write("project-icons/icon.png", "png")
    try roots.write("agent-homes/profile/.credentials", "secret")

    let report = try roots.migrate().get()

    #expect(roots.exists("settings.json", in: roots.config))
    #expect(roots.exists("shortcuts.json", in: roots.config))
    #expect(roots.exists("master-terminal/AGENTS.md", in: roots.config))
    #expect(roots.exists("catalog.json", in: roots.state))
    #expect(roots.exists("sessions.json", in: roots.state))
    #expect(roots.exists("notifications.json", in: roots.state))
    #expect(roots.exists("project-icons/icon.png", in: roots.state))
    #expect(roots.exists("agent-homes/profile/.credentials", in: roots.state))
    #expect(report.removedLegacyDirectory)
    #expect(!FileManager.default.fileExists(atPath: roots.legacy.path))
  }

  @Test
  func litterIsDeletedAndUnknownFilesAreArchived() throws {
    let roots = try makeRoots()
    defer { try? FileManager.default.removeItem(at: roots.base) }
    try roots.write("catalog.json")
    try roots.write(".DS_Store", "x")
    try roots.write(".catalog.json.tmp-1234", "partial")
    try roots.write("sessions.json.corrupt-2026.bak", "")
    try roots.write("sessions.json.lock", "")
    try roots.write("github-snapshots.json", "[]")
    try roots.write("hooks.json")
    try roots.write("catalog.json.bak")
    try roots.write("plugin-linear/state.json")

    let report = try roots.migrate().get()

    #expect(Set(report.deleted) == [
      ".DS_Store", ".catalog.json.tmp-1234", "sessions.json.corrupt-2026.bak", "sessions.json.lock",
      "github-snapshots.json",
    ])
    #expect(Set(report.archived) == ["hooks.json", "catalog.json.bak", "plugin-linear"])
    let archive = try #require(report.archiveDirectory)
    #expect(archive.lastPathComponent == "legacy-config-19700101T000000Z")
    #expect(archive.deletingLastPathComponent() == StoreBackup.directory(for: roots.state.appendingPathComponent("x")))
    #expect(roots.exists("plugin-linear/state.json", in: archive))
    #expect(report.removedLegacyDirectory)
  }

  @Test
  func existingTargetIsNeverOverwritten() throws {
    let roots = try makeRoots()
    defer { try? FileManager.default.removeItem(at: roots.base) }
    try roots.write("settings.json", #"{"new":true}"#, in: roots.config)
    try roots.write("settings.json", #"{"old":true}"#)

    let report = try roots.migrate().get()

    #expect(report.archived == ["settings.json"])
    let kept = try String(contentsOf: roots.config.appendingPathComponent("settings.json"), encoding: .utf8)
    #expect(kept == #"{"new":true}"#)
  }

  @Test
  func skipsWhenStateAlreadyHasACatalog() throws {
    let roots = try makeRoots()
    defer { try? FileManager.default.removeItem(at: roots.base) }
    try roots.write("catalog.json", in: roots.state)
    try roots.write("catalog.json")

    #expect(roots.migrate() == .failure(.alreadyMigrated))
    #expect(roots.exists("catalog.json", in: roots.legacy))
  }

  @Test
  func secondRunIsANoOp() throws {
    let roots = try makeRoots()
    defer { try? FileManager.default.removeItem(at: roots.base) }
    try roots.write("catalog.json")

    _ = try roots.migrate().get()
    #expect(roots.migrate() == .failure(.noLegacyDirectory))
  }

  @Test
  func skipsWhileAnotherProcessHoldsTheSessionLock() throws {
    let roots = try makeRoots()
    defer { try? FileManager.default.removeItem(at: roots.base) }
    try roots.write("catalog.json")
    try roots.write("sessions.json.lock", "")

    // fcntl locks held by this process are invisible to its own F_GETLK, so
    // the holder must be another process.
    let lockPath = roots.legacy.appendingPathComponent("sessions.json.lock").path
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    holder.arguments = [
      "-c",
      "import fcntl,sys,time; f=open(sys.argv[1],'r+'); fcntl.lockf(f, fcntl.LOCK_EX); print('locked', flush=True); time.sleep(30)",
      lockPath,
    ]
    let pipe = Pipe()
    holder.standardOutput = pipe
    try holder.run()
    defer { holder.terminate() }
    _ = pipe.fileHandleForReading.availableData  // wait for "locked"

    #expect(roots.migrate() == .failure(.legacyInUse))
    #expect(roots.exists("catalog.json", in: roots.legacy))
  }

  @Test
  func missingLegacyDirectorySkips() throws {
    let roots = Roots(base: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    #expect(roots.migrate() == .failure(.noLegacyDirectory))
  }
}
