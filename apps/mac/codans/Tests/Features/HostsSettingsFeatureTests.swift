import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// In-memory Host list behind `HierarchyClient`'s Host calls. It runs the
/// real `Catalog` operations, so tests see the data layer's validation.
@MainActor
final class HostListFake {
  var catalog: Catalog

  init(hosts: [HostRecord] = [], projects: [Project] = []) {
    catalog = Catalog(projects: projects, hosts: hosts)
  }

  func install(into dependencies: inout DependencyValues) {
    dependencies[HierarchyClient.self].hosts = { self.catalog.hosts }
    dependencies[HierarchyClient.self].addHost = { try self.catalog.addHost($0) }
    dependencies[HierarchyClient.self].updateHost = { try self.catalog.updateHost($0) }
    dependencies[HierarchyClient.self].removeHost = { try self.catalog.removeHost(id: $0) }
  }
}

@MainActor
struct HostsSettingsFeatureTests {
  private static let box = HostRecord(address: "box.local", username: "alice", port: 2222, name: "Box")

  private static func makeStore(
    _ fake: HostListFake,
    state: HostsSettingsFeature.State = .init()
  ) -> TestStoreOf<HostsSettingsFeature> {
    TestStore(initialState: state) {
      HostsSettingsFeature()
    } withDependencies: {
      fake.install(into: &$0)
    }
  }

  @Test
  func addSavesANewHostAndClosesTheForm() async throws {
    let fake = HostListFake()
    let store = Self.makeStore(fake)
    await store.send(.addButtonTapped) {
      $0.editor = .init(mode: .add, draft: HostDraft())
    }
    await store.send(.editor(.addressChanged(" mini.local "))) {
      $0.editor?.draft.address = " mini.local "
    }
    await store.send(.editor(.portChanged("22a22"))) {
      $0.editor?.draft.port = "2222"
    }
    await store.send(.editor(.nameChanged("Mini"))) {
      $0.editor?.draft.name = "Mini"
    }
    await store.send(.editor(.saveButtonTapped)) {
      $0.editor = nil
    }
    let added = try #require(fake.catalog.hosts.first)
    #expect(fake.catalog.hosts.count == 1)
    #expect(added.address == "mini.local")
    #expect(added.username == nil)
    #expect(added.port == 2222)
    #expect(added.name == "Mini")
  }

  @Test
  func addOfADuplicateShowsTheErrorAndKeepsTheForm() async {
    let fake = HostListFake(hosts: [Self.box])
    let draft = HostDraft(address: "box.local", username: "alice", port: "2222")
    let store = Self.makeStore(fake, state: .init(editor: .init(mode: .add, draft: draft)))
    await store.send(.editor(.saveButtonTapped)) {
      $0.editor?.errorMessage =
        "A host with the same address, username, and port already exists."
    }
    #expect(fake.catalog.hosts == [Self.box])
  }

  @Test
  func addWithoutAHostShowsTheError() async {
    let fake = HostListFake()
    let store = Self.makeStore(fake, state: .init(editor: .init(mode: .add, draft: HostDraft())))
    await store.send(.editor(.saveButtonTapped)) {
      $0.editor?.errorMessage = "Enter a host."
    }
    await store.send(.editor(.cancelButtonTapped)) {
      $0.editor = nil
    }
    #expect(fake.catalog.hosts.isEmpty)
  }

  @Test
  func addWithAnInvalidPortShowsTheError() async {
    let fake = HostListFake()
    let draft = HostDraft(address: "box.local", port: "70000")
    let store = Self.makeStore(fake, state: .init(editor: .init(mode: .add, draft: draft)))
    await store.send(.editor(.saveButtonTapped)) {
      $0.editor?.errorMessage = "Port 70000 is not valid. Enter a number from 1 to 65535."
    }
  }

  @Test
  func editChangesTheHostOfAllItsProjects() async throws {
    let first = Project(name: "a", rootPath: "/srv/a", hostID: Self.box.id, remoteHost: Self.box.endpoint)
    let second = Project(name: "b", rootPath: "/srv/b", hostID: Self.box.id, remoteHost: Self.box.endpoint)
    let fake = HostListFake(hosts: [Self.box], projects: [first, second])
    let store = Self.makeStore(fake)
    await store.send(.editButtonTapped(Self.box)) {
      $0.editor = .init(
        mode: .edit(Self.box.id),
        draft: HostDraft(address: "box.local", username: "alice", port: "2222", name: "Box")
      )
    }
    await store.send(.editor(.addressChanged("10.0.0.5"))) {
      $0.editor?.draft.address = "10.0.0.5"
    }
    await store.send(.editor(.saveButtonTapped)) {
      $0.editor = nil
    }
    let moved = RemoteHost(alias: "10.0.0.5", username: "alice", port: 2222)
    #expect(fake.catalog.hosts.map(\.id) == [Self.box.id])
    #expect(fake.catalog.projects.map(\.remoteHost) == [moved, moved])
  }

  @Test
  func editToTheFieldsOfAnotherHostShowsTheError() async {
    let other = HostRecord(address: "other.local")
    let fake = HostListFake(hosts: [Self.box, other])
    let store = Self.makeStore(fake)
    await store.send(.editButtonTapped(other)) {
      $0.editor = .init(mode: .edit(other.id), draft: HostDraft(address: "other.local"))
    }
    await store.send(.editor(.usernameChanged("alice"))) {
      $0.editor?.draft.username = "alice"
    }
    await store.send(.editor(.portChanged("2222"))) {
      $0.editor?.draft.port = "2222"
    }
    await store.send(.editor(.addressChanged("box.local"))) {
      $0.editor?.draft.address = "box.local"
    }
    await store.send(.editor(.saveButtonTapped)) {
      $0.editor?.errorMessage =
        "A host with the same address, username, and port already exists."
    }
    #expect(fake.catalog.hosts == [Self.box, other])
  }

  @Test
  func deleteRemovesAnUnusedHost() async {
    let fake = HostListFake(hosts: [Self.box])
    let store = Self.makeStore(fake, state: .init(deleteError: "old"))
    await store.send(.deleteButtonTapped(Self.box.id)) {
      $0.deleteError = nil
    }
    #expect(fake.catalog.hosts.isEmpty)
  }

  @Test
  func deleteOfAHostInUseShowsTheProjectCount() async {
    let project = Project(name: "a", rootPath: "/srv/a", hostID: Self.box.id, remoteHost: Self.box.endpoint)
    let fake = HostListFake(hosts: [Self.box], projects: [project])
    let store = Self.makeStore(fake)
    await store.send(.deleteButtonTapped(Self.box.id)) {
      $0.deleteError = "1 project uses this host. Remove the project first."
    }
    #expect(fake.catalog.hosts == [Self.box])
  }
}
