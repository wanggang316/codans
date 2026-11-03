import CodansCore
import Foundation
import Testing

@testable import Codans

/// `HierarchyManager` as the single writer of the Host list (ADR 0003):
/// Connect to Server and Edit Connection reuse a Host with the same fields,
/// and the Host operations keep every reference valid.
@MainActor
struct HierarchyManagerHostsTests {
  private static let box = RemoteHost(alias: "box.example.com", username: "me")

  private func makeManager(catalog: Catalog = .default) -> (HierarchyManager, CatalogStore, URL) {
    let url = FileManager.default.temporaryDirectory
      .appending(component: "codans-hosts-\(UUID().uuidString).json")
    let store = CatalogStore(fileURL: url)
    let manager = HierarchyManager(catalog: catalog, store: store, runtime: FakeHierarchyRuntime())
    return (manager, store, url)
  }

  @Test
  func connectingWithTheFieldsOfAnExistingHostReusesIt() throws {
    let (manager, _, _) = makeManager()
    let named = HostRecord(address: "box.example.com", username: "me", name: "Box")
    try manager.addHost(named)

    let first = manager.addServerProject(name: "a", remoteHost: Self.box, rootPath: "/srv/a")
    let second = manager.addServerProject(
      name: "b", remoteHost: RemoteHost(alias: "box.example.com", username: "me", port: 22), rootPath: "/srv/b")

    #expect(manager.catalog.hosts == [named])
    let projects = manager.catalog.projects
    #expect(projects.first { $0.id == first }?.hostID == named.id)
    #expect(projects.first { $0.id == second }?.hostID == named.id)
    #expect(projects.first { $0.id == first }?.remoteHost == named.endpoint)
  }

  @Test
  func connectingWithNewFieldsAddsAHost() {
    let (manager, _, _) = makeManager()
    let id = manager.addServerProject(name: "a", remoteHost: Self.box, rootPath: "/srv/a")
    #expect(manager.catalog.hosts.map(\.endpoint) == [Self.box])
    #expect(manager.catalog.projects.first { $0.id == id }?.hostID == manager.catalog.hosts[0].id)
  }

  @Test
  func editConnectionSwitchesHostAndKeepsTheOldRecord() throws {
    let (manager, _, _) = makeManager()
    let id = manager.addServerProject(name: "a", remoteHost: Self.box, rootPath: "/srv/a")
    let oldHost = try #require(manager.catalog.hosts.first)
    let moved = RemoteHost(alias: "box.example.com", username: "me", port: 2200)

    manager.updateServerProject(projectID: id, remoteHost: moved, rootPath: "/srv/a", gitRoot: nil)

    #expect(manager.catalog.hosts.map(\.endpoint) == [Self.box, moved])
    let project = try #require(manager.catalog.projects.first { $0.id == id })
    #expect(project.hostID == manager.catalog.hosts[1].id)
    #expect(project.remoteHost == moved)
    #expect(manager.catalog.projectCount(onHost: oldHost.id) == 0)
  }

  @Test
  func duplicateAddAndInUseDeleteAreRefused() throws {
    let (manager, _, _) = makeManager()
    _ = manager.addServerProject(name: "a", remoteHost: Self.box, rootPath: "/srv/a")
    let host = try #require(manager.catalog.hosts.first)

    #expect(throws: HostRecordError.duplicate(existing: host.id)) {
      try manager.addHost(HostRecord(endpoint: Self.box))
    }
    #expect(throws: HostRecordError.inUse(projectCount: 1)) { try manager.removeHost(host.id) }
    #expect(manager.catalog.hosts == [host])
  }

  @Test
  func editingAHostReachesItsProjectsAndPersists() throws {
    let (manager, store, url) = makeManager()
    let id = manager.addServerProject(name: "a", remoteHost: Self.box, rootPath: "/srv/a")
    var host = try #require(manager.catalog.hosts.first)
    host.name = "Build box"
    host.port = 2222

    try manager.updateHost(host)
    store.flushPending()

    #expect(manager.catalog.projects.first { $0.id == id }?.remoteHost?.port == 2222)
    let reloaded = try CatalogStore(fileURL: url).load()
    #expect(reloaded.hosts == [host])
    #expect(reloaded.projects.first { $0.id == id }?.remoteHost == host.endpoint)
  }

  @Test
  func unusedHostCanBeDeleted() throws {
    let (manager, _, _) = makeManager()
    let record = HostRecord(address: "spare")
    try manager.addHost(record)
    try manager.removeHost(record.id)
    #expect(manager.catalog.hosts.isEmpty)
  }

  @Test
  func inMemoryServerProjectsAreAttachedAtInit() {
    let catalog = Catalog(projects: [Project(name: "a", rootPath: "/srv/a", remoteHost: Self.box)])
    let (manager, _, _) = makeManager(catalog: catalog)
    #expect(manager.catalog.hosts.map(\.endpoint) == [Self.box])
    #expect(manager.catalog.projects[0].hostID == manager.catalog.hosts[0].id)
  }
}
