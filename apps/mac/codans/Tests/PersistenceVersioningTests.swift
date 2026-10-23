import CodansCore
import Foundation
import Testing

@testable import Codans

/// On-disk versioning of the small stores that used to be bare JSON, and the
/// catalog's refusal to overwrite a file it could not read.
@MainActor
struct PersistenceVersioningTests {
  private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-persistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func jsonObject(at url: URL) throws -> [String: Any]? {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
  }

  @Test
  func remoteHostSidecarReadsLegacyMapAndWritesEnvelope() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("remote-hosts.json")
    let host = RemoteHost(alias: "mini.local", username: "alice")
    let project = Project(name: "srv", rootPath: "/data/app", remoteHost: host)
    let legacy = [project.id.raw.uuidString: host]
    try AtomicFileStore.write(legacy, to: url)

    #expect(RemoteHostSidecar.read(at: url) == legacy)

    var catalog = Catalog()
    catalog.projects = [project]
    RemoteHostSidecar.sync(from: catalog, to: url)
    #expect(try jsonObject(at: url)?["version"] as? Int == RemoteHostSidecar.currentVersion)
    #expect(RemoteHostSidecar.read(at: url) == legacy)
  }

  @Test
  func savedServerHostsReadsLegacyArrayAndWritesEnvelope() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("saved-server-hosts.json")
    let old = RemoteHost(alias: "old.local")
    try AtomicFileStore.write([old], to: url)

    let new = RemoteHost(alias: "new.local")
    SavedServerHosts.record(new, at: url)

    #expect(try jsonObject(at: url)?["version"] as? Int == SavedServerHosts.currentVersion)
    #expect(SavedServerHosts.read(at: url) == [new, old])
  }

  @Test
  func githubSnapshotsUseStringKeysAndDropTheOldShape() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("github-snapshots.json")
    try Data(#"[{"raw":"00000000-0000-0000-0000-000000000001"},null]"#.utf8).write(to: url)

    let cache = GitHubSnapshotCache(fileURL: url)
    #expect(cache.load().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))

    let id = ProjectID()
    let snapshot = BatchedPullRequests(
      host: "github.com", owner: "w", repo: "r",
      byBranch: [:], seenBranches: ["main"], fetchedAt: Date(timeIntervalSince1970: 1)
    )
    cache.save([id: snapshot], sequence: 1)
    let object = try jsonObject(at: url)
    #expect(object?["version"] as? Int == GitHubSnapshotCache.currentVersion)
    #expect((object?["entries"] as? [String: Any])?.keys.contains(id.raw.uuidString) == true)
    #expect(cache.load().keys.contains(id))
  }

  @Test
  func retiredCatalogVersionIsMovedAsideAndLoadStartsEmpty() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("catalog.json")
    let retired = Data(#"{"version": 2, "spaces": []}"#.utf8)
    try retired.write(to: url)

    let store = CatalogStore(fileURL: url)
    let loaded = try store.load()

    #expect(loaded.projects.isEmpty)
    #expect(store.persistenceEnabled)
    #expect(store.loadIssue == nil)
    let backups = try backupNames(for: url)
    #expect(backups.contains { $0.hasPrefix("catalog.unsupported-v2-") })
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  // MARK: - Catalog 3 → 4

  private func workspaceCatalogV3() -> Catalog {
    let pane = Pane(workingDirectory: "/tmp/ws")
    let tab = Tab(splitTree: SplitTree(leaf: pane.id), panes: [pane])
    let root = Worktree(name: "ws", path: "/tmp/ws", tabs: [tab], selectedTabID: tab.id)
    let child = Worktree(name: "app", path: "/tmp/ws/app", branch: "feat/x", sourceGitRoot: "/src/app")
    let project = Project(
      name: "ws", rootPath: "/tmp/ws", worktrees: [root, child], selectedWorktreeID: root.id,
      isWorkspace: true)
    return Catalog(version: 3, projects: [project], selectedProjectID: project.id)
  }

  private func backupNames(for url: URL) throws -> [String] {
    let directory = StoreBackup.directory(for: url)
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: directory.path)
  }

  @Test
  func versionThreeCatalogMigratesWritesVersionFourAndKeepsACopy() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("catalog.json")
    let legacy = workspaceCatalogV3()
    try AtomicFileStore.write(legacy, to: url)
    let original = try Data(contentsOf: url)

    let store = CatalogStore(fileURL: url)
    let loaded = try store.load()

    #expect(loaded.version == 4)
    #expect(store.persistenceEnabled)
    #expect(store.loadIssue == nil)
    let project = try #require(loaded.projects.first)
    #expect(project.worktrees.map(\.id) == legacy.projects[0].worktrees.map(\.id))
    #expect(project.worktrees[0].tabs == legacy.projects[0].worktrees[0].tabs)
    #expect(project.selectedWorktreeID == legacy.projects[0].selectedWorktreeID)
    #expect(loaded.selectedProjectID == legacy.selectedProjectID)
    #expect(project.worktrees[0].workspaceSlot?.role == .groupTerminal)
    #expect(project.workspaceGroups.map(\.name) == ["default", "existing"])

    let onDisk = try #require(try jsonObject(at: url))
    #expect(onDisk["version"] as? Int == 4)
    let backups = try backupNames(for: url)
    #expect(backups.count == 1)
    let backup = StoreBackup.directory(for: url).appendingPathComponent(try #require(backups.first))
    #expect(backup.lastPathComponent.hasPrefix("catalog.migrated-v3-"))
    #expect(try Data(contentsOf: backup) == original)
  }

  @Test
  func secondLoadOfAMigratedCatalogChangesNothing() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("catalog.json")
    try AtomicFileStore.write(workspaceCatalogV3(), to: url)
    let first = try CatalogStore(fileURL: url).load()
    let afterFirst = try Data(contentsOf: url)

    let second = try CatalogStore(fileURL: url).load()

    #expect(second == first)
    #expect(second.projects[0].workspaceGroups.count == 2)
    #expect(try Data(contentsOf: url) == afterFirst)
    #expect(try backupNames(for: url).count == 1)
  }

  @Test
  func newerCatalogStaysInPlaceWithSavingOffAndAnIssue() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("catalog.json")
    let future = Data(#"{"version": 5, "projects": [], "futureField": true}"#.utf8)
    try future.write(to: url)

    let store = CatalogStore(fileURL: url)
    let loaded = try store.load()

    #expect(loaded.projects.isEmpty)
    #expect(!store.persistenceEnabled)
    #expect(store.loadIssue == .newerVersion(5))
    try store.saveNow(Catalog(projects: [Project(name: "p", rootPath: "/p")]))
    store.scheduleSave(Catalog())
    store.flushPending()
    #expect(try Data(contentsOf: url) == future)
    let backups = try backupNames(for: url)
    #expect(backups.contains { $0.hasPrefix("catalog.unsupported-v5-") })
  }

  @Test
  func failedMigrationBackupDisablesSaving() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("catalog.json")
    try AtomicFileStore.write(workspaceCatalogV3(), to: url)
    let original = try Data(contentsOf: url)
    // A regular file where `backups/` must go makes the copy fail.
    try Data().write(to: StoreBackup.directory(for: url))

    let store = CatalogStore(fileURL: url)
    let loaded = try store.load()

    #expect(loaded.version == 4)
    #expect(loaded.projects[0].workspaceGroups.count == 2)
    #expect(!store.persistenceEnabled)
    #expect(store.loadIssue == .migrationBackupFailed)
    #expect(try Data(contentsOf: url) == original)
  }
}
