import CodansCore
import Foundation
import Testing

@testable import Codans

/// `CatalogStore.load()` re-derives `isWorkspace` from the manifest on disk
/// and persists the healed catalog, mirroring the remote-host sidecar repair.
@MainActor
struct CatalogStoreWorkspaceRepairTests {
  @Test
  func loadRestoresStrippedWorkspaceFlagAndPersistsIt() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("codans-ws-repair-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let root = dir.appendingPathComponent("ws", isDirectory: true)
    let rootPath = root.path(percentEncoded: false)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try WorkspaceManifestStore.save(WorkspaceManifest(title: "ws"), rootPath: rootPath)

    // What an older build leaves behind: flag gone, a probed gitRoot in place.
    var stripped = Catalog()
    stripped.projects = [Project(name: "ws", rootPath: rootPath, gitRoot: dir.path)]
    let catalogURL = dir.appendingPathComponent("catalog.json")
    try AtomicFileStore.write(stripped, to: catalogURL)

    let loaded = try CatalogStore(fileURL: catalogURL).load()
    #expect(loaded.projects[0].isWorkspace)
    #expect(loaded.projects[0].gitRoot == nil)
    #expect(loaded.projects[0].kind == .workspace)

    // The repair is written straight back so a crash before the next
    // debounced save cannot lose it.
    let onDisk = try #require(try AtomicFileStore.read(Catalog.self, at: catalogURL))
    #expect(onDisk.projects[0].isWorkspace)
  }
}
