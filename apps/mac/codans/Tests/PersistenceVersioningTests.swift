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
  func unreadableCatalogIsBackedUpBeforeAnythingCanOverwriteIt() throws {
    let directory = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("catalog.json")
    let future = Data(#"{"version": 99, "projects": []}"#.utf8)
    try future.write(to: url)

    let store = CatalogStore(fileURL: url)
    let loaded = try store.load()

    #expect(loaded.projects.isEmpty)
    #expect(store.persistenceEnabled)
    let backups = try FileManager.default.contentsOfDirectory(
      at: StoreBackup.directory(for: url), includingPropertiesForKeys: nil)
    #expect(backups.map(\.lastPathComponent).contains { $0.hasPrefix("catalog.unsupported-v99-") })
    #expect(try Data(contentsOf: backups[0]) == future)
  }
}
