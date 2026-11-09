import Foundation
import Testing
import CodansCore

@testable import Codans

/// Coverage for the Project order manager APIs (ADR 0001):
/// - `HierarchyManager.moveProject` (sidebar block drag)
/// - `HierarchyManager.addProject` appends and populates `addedAt`
/// - `HierarchyManager.bumpProjectActivity`
@MainActor
struct HierarchyManagerProjectOrderTests {
  var fakeRuntime: FakeHierarchyRuntime!
  var store: CatalogStore!
  var manager: HierarchyManager!
  let catalogURL: URL

  init() {
    catalogURL = FileManager.default.temporaryDirectory
      .appending(component: UUID().uuidString + ".json")
    fakeRuntime = FakeHierarchyRuntime()
    store = CatalogStore(fileURL: catalogURL)
    manager = HierarchyManager(catalog: .default, store: store, runtime: fakeRuntime)
  }

  @Test
  func addProjectStampsAddedAtAndAppends() {
    let before = Date()
    let pidA = manager.addProject(name: "a", rootPath: "/a", gitRoot: nil)
    let pidB = manager.addRemoteProject(
      name: "b", remoteHost: RemoteHost(alias: "box"), rootPath: "/srv/b")
    let pidC = manager.addProject(name: "c", rootPath: "/c", gitRoot: nil)
    let after = Date()

    #expect(manager.catalog.projects.map(\.id) == [pidA, pidB, pidC])
    let projectA = manager.catalog.projects.first { $0.id == pidA }!
    let projectC = manager.catalog.projects.first { $0.id == pidC }!
    #expect(projectA.addedAt >= before)
    #expect(projectC.addedAt <= after)
    #expect(projectA.lastActiveAt == nil)
  }

  @Test
  func moveProjectPersistsAcrossRestart() throws {
    let a = manager.addProject(name: "a", rootPath: "/a", gitRoot: nil)
    let b = manager.addProject(name: "b", rootPath: "/b", gitRoot: nil)
    let c = manager.addProject(name: "c", rootPath: "/c", gitRoot: nil)

    manager.moveProject(c, to: .before(a))
    #expect(manager.catalog.projects.map(\.id) == [c, a, b])
    store.flushPending()

    let reloaded = try CatalogStore(fileURL: catalogURL).load()
    #expect(reloaded.projects.map(\.id) == [c, a, b])
  }

  @Test
  func moveProjectToSamePositionDoesNotSchedulePersist() throws {
    let a = manager.addProject(name: "a", rootPath: "/a", gitRoot: nil)
    let b = manager.addProject(name: "b", rootPath: "/b", gitRoot: nil)
    store.flushPending()
    let saved = try Data(contentsOf: catalogURL)

    manager.moveProject(b, to: .after(a))
    manager.moveProject(a, to: .before(a))
    #expect(manager.catalog.projects.map(\.id) == [a, b])
    store.flushPending()
    #expect(try Data(contentsOf: catalogURL) == saved)
  }

  @Test
  func bumpProjectActivityMonotonic() {
    let pid = manager.addProject(name: "p", rootPath: "/p", gitRoot: nil)
    let t1 = Date(timeIntervalSince1970: 1000)
    let t2 = Date(timeIntervalSince1970: 2000)
    let stale = Date(timeIntervalSince1970: 500)

    manager.bumpProjectActivity(pid, now: t1)
    #expect(manager.catalog.projects.first { $0.id == pid }?.lastActiveAt == t1)

    manager.bumpProjectActivity(pid, now: stale)  // older — must not rewind
    #expect(manager.catalog.projects.first { $0.id == pid }?.lastActiveAt == t1)

    manager.bumpProjectActivity(pid, now: t2)
    #expect(manager.catalog.projects.first { $0.id == pid }?.lastActiveAt == t2)
  }

  @Test
  func bumpProjectActivityUnknownIDIsNoOp() {
    let bogus = ProjectID()
    manager.bumpProjectActivity(bogus)
    // No projects exist; nothing to assert beyond no crash + no panic.
    #expect(manager.catalog.projects.isEmpty)
  }
}
