import CodansCore
import Foundation
import Testing

@testable import Codans

struct RemoteHostSidecarTests {
  private static let host = RemoteHost(alias: "mini.local", username: "alice")

  private func tempSidecar() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-sidecar-\(UUID().uuidString)")
      .appendingPathComponent("remote-hosts.json")
  }

  @Test
  func repairRestoresStrippedHostAndLeavesLocalProjectsAlone() throws {
    let url = tempSidecar()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let server = Project(name: "srv", rootPath: "/data/app", remoteHost: Self.host)
    let local = Project(name: "loc", rootPath: "/tmp/x")
    var catalog = Catalog()
    catalog.projects = [server, local]

    // A save mirrors the server project into the sidecar…
    RemoteHostSidecar.sync(from: catalog, to: url)
    // …then an old build strips the field (tolerant decode + re-encode).
    catalog.projects[0].remoteHost = nil

    #expect(RemoteHostSidecar.repair(&catalog, sidecarURL: url))
    #expect(catalog.projects[0].remoteHost == Self.host)
    // The genuinely-local project never gains a host.
    #expect(catalog.projects[1].remoteHost == nil)
    // Nothing left to repair → false.
    #expect(!RemoteHostSidecar.repair(&catalog, sidecarURL: url))
  }

  @Test
  func syncPrunesRemovedProjectsButKeepsStrippedOnes() throws {
    let url = tempSidecar()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let kept = Project(name: "kept", rootPath: "/data/a", remoteHost: Self.host)
    let removed = Project(
      name: "removed", rootPath: "/data/b",
      remoteHost: RemoteHost(alias: "other.local"))
    var catalog = Catalog()
    catalog.projects = [kept, removed]
    RemoteHostSidecar.sync(from: catalog, to: url)
    #expect(RemoteHostSidecar.read(at: url).count == 2)

    // Project removed on purpose → its entry is pruned. A project still in
    // the catalog but with a stripped host KEEPS its entry — that is the
    // exact failure the sidecar absorbs.
    catalog.projects.removeAll { $0.id == removed.id }
    catalog.projects[0].remoteHost = nil
    RemoteHostSidecar.sync(from: catalog, to: url)
    let entries = RemoteHostSidecar.read(at: url)
    #expect(entries.count == 1)
    #expect(entries[kept.id.raw.uuidString] == Self.host)
  }

  @Test
  func syncRemovesFileWhenNoServerProjectsRemain() throws {
    let url = tempSidecar()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    var catalog = Catalog()
    catalog.projects = [Project(name: "srv", rootPath: "/data/app", remoteHost: Self.host)]
    RemoteHostSidecar.sync(from: catalog, to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))

    catalog.projects = []
    RemoteHostSidecar.sync(from: catalog, to: url)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
}
