import CodansCore
import Foundation
import Testing

@testable import Codans

/// `CatalogStore.load()` against files on disk: a v3 file is backed up by
/// copy and rewritten as v4 at once; a file from a newer build is left
/// byte-identical and the store goes read-only; a current file with an
/// unreadable Tab surfaces the loss count that gates the session sweeps.
@MainActor
struct CatalogStoreTests {
  private static func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
  }

  private static func id(_ n: Int) -> String { #"{ "raw": "\#(uuid(n))" }"# }

  private static func tab(_ n: Int) -> String {
    #"{ "id": \#(id(n)), "content": { "id": \#(id(n + 100)), "state": { "kind": "terminal", "terminal": { "workingDirectory": "/repo" } } } }"#
  }

  private static func v4(panes: String) -> Data {
    let worktree =
      #"{ "id": \#(id(20)), "name": "w", "path": "/repo", "splitTree": { "root": { "leaf": { "_0": \#(id(10)) } } }, "panes": [\#(panes)], "focusedPaneID": \#(id(10)) }"#
    let project = #"{ "id": \#(id(30)), "name": "p", "rootPath": "/repo", "worktrees": [\#(worktree)] }"#
    return Data(#"{ "version": 4, "projects": [\#(project)] }"#.utf8)
  }

  private static func v3() -> Data {
    let formerTab =
      #"{ "id": \#(id(1)), "splitTree": { "root": { "leaf": { "_0": \#(id(101)) } } }, "panes": [{ "id": \#(id(101)), "workingDirectory": "/repo" }] }"#
    let worktree =
      #"{ "id": \#(id(20)), "name": "w", "path": "/repo", "tabs": [\#(formerTab)], "selectedTabID": \#(id(1)) }"#
    let project = #"{ "id": \#(id(30)), "name": "p", "rootPath": "/repo", "worktrees": [\#(worktree)] }"#
    return Data(#"{ "version": 3, "projects": [\#(project)] }"#.utf8)
  }

  private struct Sandbox {
    let directory: URL
    let catalogURL: URL

    init() throws {
      directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codans-catalog-store-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      catalogURL = directory.appendingPathComponent("catalog.json")
    }

    func tearDown() {
      try? FileManager.default.removeItem(at: directory)
    }

    var backups: [String] {
      (try? FileManager.default.contentsOfDirectory(
        atPath: directory.appendingPathComponent(StoreBackup.directoryName).path)) ?? []
    }
  }

  @Test
  func version3IsBackedUpByCopyAndRewrittenAsVersion4() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    let original = Self.v3()
    try original.write(to: sandbox.catalogURL)

    let store = CatalogStore(fileURL: sandbox.catalogURL)
    let loaded = try store.load()

    #expect(store.loadReport.migratedFromVersion == 3)
    #expect(store.loadReport.allowsSessionSweeps)
    #expect(store.persistenceEnabled)
    // The session keeps its id across the migration.
    #expect(loaded.projects[0].worktrees[0].contentIDs == [ContentID(raw: Self.uuid(101))])

    // Written at once, as the current version.
    let onDisk = try Data(contentsOf: sandbox.catalogURL)
    #expect(try Catalog.peekVersion(in: onDisk) == Catalog.currentVersion)
    let reloaded = try #require(try AtomicFileStore.read(Catalog.self, at: sandbox.catalogURL))
    #expect(reloaded.projects[0].worktrees[0].panes.count == 1)

    // A copy of the v3 bytes sits in `backups/`.
    let backups = sandbox.backups.filter { $0.contains("migrated-v3") }
    #expect(backups.count == 1)
    if let name = backups.first {
      let copy = try Data(
        contentsOf: sandbox.directory.appendingPathComponent(StoreBackup.directoryName).appendingPathComponent(name))
      #expect(copy == original)
    }
  }

  @Test
  func newerVersionIsReadOnlyAndLeavesTheFileUntouched() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    let original = Data(#"{ "version": 9, "projects": [], "futureField": true }"#.utf8)
    try original.write(to: sandbox.catalogURL)
    let before = try FileManager.default.attributesOfItem(atPath: sandbox.catalogURL.path)[.modificationDate] as? Date

    let store = CatalogStore(fileURL: sandbox.catalogURL)
    let loaded = try store.load()

    #expect(loaded == .default)
    #expect(store.loadReport.readOnlyVersion == 9)
    #expect(store.loadReport.isReadOnly)
    #expect(!store.loadReport.allowsSessionSweeps)
    #expect(!store.persistenceEnabled)
    #expect(sandbox.backups.isEmpty)

    // Every save path is a no-op.
    var mutated = Catalog()
    mutated.projects = [Project(name: "p", rootPath: "/x", gitRoot: "/x")]
    try store.saveNow(mutated)
    store.scheduleSave(mutated)
    store.flushPending()
    #expect(try Data(contentsOf: sandbox.catalogURL) == original)
    let after = try FileManager.default.attributesOfItem(atPath: sandbox.catalogURL.path)[.modificationDate] as? Date
    #expect(before == after)
  }

  @Test
  func unreadableTabSurfacesTheLossCount() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try Self.v4(panes: #"{ "id": \#(Self.id(10)), "tabs": [\#(Self.tab(1)), "not a tab"] }"#)
      .write(to: sandbox.catalogURL)

    let store = CatalogStore(fileURL: sandbox.catalogURL)
    let loaded = try store.load()

    #expect(store.loadReport.droppedTabs == 1)
    #expect(store.loadReport.decodeLossCount == 1)
    #expect(!store.loadReport.allowsSessionSweeps)
    #expect(!store.loadReport.isReadOnly)
    #expect(store.persistenceEnabled)
    #expect(loaded.projects[0].worktrees[0].panes[0].tabs.count == 1)
  }

  @Test
  func cleanCurrentFileAllowsSessionSweeps() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try Self.v4(panes: #"{ "id": \#(Self.id(10)), "tabs": [\#(Self.tab(1))] }"#).write(to: sandbox.catalogURL)

    let store = CatalogStore(fileURL: sandbox.catalogURL)
    _ = try store.load()

    #expect(store.loadReport == .clean)
    #expect(store.loadReport.allowsSessionSweeps)
  }

  /// A v3 file whose record cannot be read: the launch path gets an empty
  /// catalog, but with saving and every session sweep off, and the file
  /// left byte-identical with a copy in `backups/`.
  @Test
  func malformedVersion3TurnsSweepsAndSavingOff() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    let original = Data(#"{ "version": 3, "projects": [{ "id": 5, "name": "p" }] }"#.utf8)
    try original.write(to: sandbox.catalogURL)

    let store = CatalogStore(fileURL: sandbox.catalogURL)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(store.loadReport.loadFailed)
    #expect(!store.loadReport.allowsSessionSweeps)
    #expect(!store.persistenceEnabled)

    let launched = store.loadForLaunch()
    #expect(launched == .empty)
    #expect(!store.loadReport.allowsSessionSweeps)
    store.scheduleSave(launched)
    store.flushPending()
    try store.saveNow(launched)

    #expect(try Data(contentsOf: sandbox.catalogURL) == original)
    let copies = sandbox.backups.filter { $0.contains("corrupt") }
    #expect(copies.count == 2)
    if let name = copies.first {
      let copy = try Data(
        contentsOf: sandbox.directory.appendingPathComponent(StoreBackup.directoryName).appendingPathComponent(name))
      #expect(copy == original)
    }
  }

  /// A current file that breaks a layout invariant takes the same path.
  @Test
  func brokenLayoutTurnsSweepsAndSavingOff() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    // The split tree names Pane 10, but the Worktree holds no Pane.
    let original = Self.v4(panes: "")
    try original.write(to: sandbox.catalogURL)

    let store = CatalogStore(fileURL: sandbox.catalogURL)
    #expect(store.loadForLaunch() == .empty)
    #expect(store.loadReport.loadFailed)
    #expect(!store.loadReport.allowsSessionSweeps)
    #expect(!store.persistenceEnabled)
    #expect(try Data(contentsOf: sandbox.catalogURL) == original)
  }

  /// The file exists but cannot be read at all (here: a directory).
  @Test
  func unreadableFileTurnsSweepsAndSavingOff() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try FileManager.default.createDirectory(at: sandbox.catalogURL, withIntermediateDirectories: false)

    let store = CatalogStore(fileURL: sandbox.catalogURL)
    #expect(store.loadForLaunch() == .empty)
    #expect(store.loadReport.loadFailed)
    #expect(!store.loadReport.allowsSessionSweeps)
    #expect(!store.persistenceEnabled)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: sandbox.catalogURL.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }
}
