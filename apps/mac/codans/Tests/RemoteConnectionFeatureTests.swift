import CodansCore
import ComposableArchitecture
import Foundation
import Testing

@testable import Codans

/// Reducer-level coverage for `RemoteConnectionFeature`'s pure paths — the
/// Host picker, "New Host…" fields, and the pre-flight validation that runs
/// *before* any SSH probe. The network validation pipeline
/// (`connectButtonTapped` → `.run`) is not exercised here; it depends on a
/// reachable host.
@MainActor
struct RemoteConnectionFeatureTests {
  private static let box = HostRecord(address: "box.local", username: "alice", port: 2222, name: "Box")
  private static let mini = HostRecord(address: "mini.local")

  @Test
  func pickerDefaultsToTheFirstHostOrNewHost() {
    let withHosts = RemoteConnectionFeature.State(hosts: [Self.box, Self.mini])
    #expect(withHosts.hostChoice == .existing(Self.box.id))
    #expect(!withHosts.isNewHost)
    let empty = RemoteConnectionFeature.State()
    #expect(empty.hostChoice == .newHost)
    #expect(empty.isNewHost)
  }

  @Test
  func choosingAHostClearsTheError() async {
    let store = TestStore(
      initialState: RemoteConnectionFeature.State(hosts: [Self.box, Self.mini], errorMessage: "old")
    ) {
      RemoteConnectionFeature()
    }
    await store.send(.hostChoiceChanged(.existing(Self.mini.id))) {
      $0.hostChoice = .existing(Self.mini.id)
      $0.errorMessage = nil
    }
    await store.send(.hostChoiceChanged(.newHost)) {
      $0.hostChoice = .newHost
    }
  }

  @Test
  func newHostFieldsEditTheDraft() async {
    let store = TestStore(initialState: RemoteConnectionFeature.State()) {
      RemoteConnectionFeature()
    }
    await store.send(.addressChanged("example.com")) {
      $0.newHost.address = "example.com"
    }
    await store.send(.usernameChanged("alice")) {
      $0.newHost.username = "alice"
    }
    await store.send(.portChanged("2a2b2")) {
      $0.newHost.port = "222"
    }
    await store.send(.portChanged("1234567")) {
      $0.newHost.port = "12345"
    }
    await store.send(.nameChanged("Example")) {
      $0.newHost.name = "Example"
    }
    await store.send(.iconChanged(.cloud)) {
      $0.newHost.icon = .cloud
    }
    #expect(store.state.canConnect == false)
    await store.send(.pathChanged("/srv/app")) {
      $0.pathDraft = "/srv/app"
    }
    #expect(store.state.canConnect)
  }

  @Test
  func connectRejectsEmptyNewHost() async {
    let store = TestStore(initialState: RemoteConnectionFeature.State(pathDraft: "/srv/app")) {
      RemoteConnectionFeature()
    }
    // No host → validation error, no effect (no SSH probe launched).
    await store.send(.connectButtonTapped) {
      $0.errorMessage = "Enter a host."
    }
  }

  @Test
  func connectRejectsEmptyPath() async {
    let store = TestStore(initialState: RemoteConnectionFeature.State(hosts: [Self.box])) {
      RemoteConnectionFeature()
    }
    await store.send(.connectButtonTapped) {
      $0.errorMessage = "Enter the remote path to open."
    }
  }

  @Test
  func connectRejectsOutOfRangePort() async {
    let store = TestStore(
      initialState: RemoteConnectionFeature.State(
        newHost: HostDraft(address: "example.com", port: "70000"), pathDraft: "/srv/app"
      )
    ) {
      RemoteConnectionFeature()
    }
    await store.send(.connectButtonTapped) {
      $0.errorMessage = "Port 70000 is not valid. Enter a number from 1 to 65535."
    }
  }

  @Test
  func selectedHostIsThePickedRecord() throws {
    let state = RemoteConnectionFeature.State(
      hosts: [Self.box, Self.mini], hostChoice: .existing(Self.mini.id)
    )
    #expect(try state.selectedHost() == Self.mini)
    let stale = RemoteConnectionFeature.State(hosts: [Self.box], hostChoice: .existing(HostID()))
    #expect(throws: HostRecordError.self) { try stale.selectedHost() }
  }

  @Test
  func newHostEqualToAnExistingHostUsesThatHost() throws {
    // Same (Host, Username, Port) as `box`; the Name is not part of identity.
    let state = RemoteConnectionFeature.State(
      hosts: [Self.box],
      hostChoice: .newHost,
      newHost: HostDraft(address: " box.local ", username: "alice", port: "2222", name: "Other")
    )
    #expect(try state.selectedHost() == Self.box)
  }

  @Test
  func newHostMakesANewRecordWithItsName() throws {
    let state = RemoteConnectionFeature.State(
      hosts: [Self.box],
      hostChoice: .newHost,
      newHost: HostDraft(address: "new.local", username: "", port: "", name: "New", icon: .macStudio)
    )
    let record = try state.selectedHost()
    #expect(record.id != Self.box.id)
    #expect(record.address == "new.local")
    #expect(record.username == nil)
    #expect(record.port == nil)
    #expect(record.name == "New")
    #expect(record.icon == .macStudio)
  }

  @Test
  func editingSeedsHostChoiceAndPathFromServerProject() {
    let project = Project(
      name: "app", rootPath: "/srv/app", gitRoot: "/srv/app",
      hostID: Self.mini.id, remoteHost: Self.mini.endpoint
    )
    let seeded = RemoteConnectionFeature.State.editing(project: project, hosts: [Self.box, Self.mini])
    #expect(seeded?.mode == .edit(projectID: project.id))
    #expect(seeded?.isEditing == true)
    #expect(seeded?.hostChoice == .existing(Self.mini.id))
    #expect(seeded?.newHost == HostDraft())
    #expect(seeded?.pathDraft == "/srv/app")
    // A local project has no connection to edit.
    let local = Project(name: "local", rootPath: "/tmp/x")
    #expect(RemoteConnectionFeature.State.editing(project: local, hosts: [Self.box]) == nil)
  }

  @Test
  func editingAProjectWithoutAHostRecordSeedsNewHostFields() {
    let endpoint = RemoteHost(alias: "legacy.local", username: "bob", port: 2200)
    let project = Project(name: "app", rootPath: "/srv/app", remoteHost: endpoint)
    let seeded = RemoteConnectionFeature.State.editing(project: project, hosts: [Self.box])
    #expect(seeded?.hostChoice == .newHost)
    #expect(seeded?.newHost == HostDraft(address: "legacy.local", username: "bob", port: "2200"))
  }

  @Test
  func connectSucceededDelegatesConnected() async {
    let store = TestStore(
      initialState: RemoteConnectionFeature.State(hosts: [Self.box], isConnecting: true)
    ) {
      RemoteConnectionFeature()
    }
    await store.send(.connectSucceeded(host: Self.box, remotePath: "/srv/app", gitRoot: "/srv/app")) {
      $0.isConnecting = false
    }
    await store.receive(\.delegate.connected)
  }
}

/// The sidebar side of the picker flows: what `HierarchySidebarFeature` writes
/// through `HierarchyClient` when the sheet opens and when it connects.
@MainActor
struct RemoteConnectionSidebarFlowTests {
  private static let box = HostRecord(address: "box.local", username: "alice", port: 2222, name: "Box")
  private static let mini = HostRecord(address: "mini.local")

  @MainActor
  final class Recorder {
    var added: [(name: String, endpoint: RemoteHost, path: String)] = []
    var updated: [(projectID: ProjectID, endpoint: RemoteHost, path: String)] = []
  }

  private static func makeStore(
    _ fake: HostListFake,
    _ recorder: Recorder,
    state: HierarchySidebarFeature.State = .init()
  ) -> TestStoreOf<HierarchySidebarFeature> {
    let store = TestStore(initialState: state) {
      HierarchySidebarFeature()
    } withDependencies: {
      fake.install(into: &$0)
      $0.hierarchyClient.snapshot = { fake.catalog }
      $0.hierarchyClient.addServerProject = { name, endpoint, path, _ in
        recorder.added.append((name, endpoint, path))
        return ProjectID()
      }
      $0.hierarchyClient.updateServerProject = { projectID, endpoint, path, _ in
        recorder.updated.append((projectID, endpoint, path))
      }
    }
    store.exhaustivity = .off
    return store
  }

  @Test
  func connectServerOpensThePickerWithTheHostList() async {
    let fake = HostListFake(hosts: [Self.box, Self.mini])
    let store = Self.makeStore(fake, Recorder())
    await store.send(.connectServerTapped) {
      $0.remoteConnectionSheet = RemoteConnectionFeature.State(hosts: [Self.box, Self.mini])
    }
  }

  @Test
  func connectWithAnExistingHostAddsNoHost() async {
    let fake = HostListFake(hosts: [Self.box])
    let recorder = Recorder()
    let store = Self.makeStore(
      fake, recorder, state: .init(remoteConnectionSheet: .init(hosts: [Self.box]))
    )
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: Self.box, remotePath: "/srv/app", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet = nil
    }
    #expect(fake.catalog.hosts == [Self.box])
    #expect(recorder.added.count == 1)
    #expect(recorder.added.first?.name == "app")
    #expect(recorder.added.first?.endpoint == Self.box.endpoint)
  }

  // MARK: - Duplicate Host + path (ADR 0006)

  @Test
  func connectToAnExistingHostAndPathSelectsThatProjectAndAddsNothing() async {
    let existing = Project(
      name: "app", rootPath: "/srv/app", hostID: Self.box.id, remoteHost: Self.box.endpoint
    )
    let fake = HostListFake(hosts: [Self.box], projects: [existing])
    let recorder = Recorder()
    let store = Self.makeStore(
      fake, recorder, state: .init(remoteConnectionSheet: .init(hosts: [Self.box]))
    )
    // The remote form ignores a trailing slash.
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: Self.box, remotePath: "/srv/app/", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet = nil
    }
    await store.receive(\.delegate.revealExistingProject, existing.id)
    #expect(recorder.added.isEmpty)
  }

  @Test
  func connectToAPathThatOnlyALocalProjectHasAddsAServerProject() async {
    let local = Project(name: "app", rootPath: "/srv/app")
    let fake = HostListFake(hosts: [Self.box], projects: [local])
    let recorder = Recorder()
    let store = Self.makeStore(
      fake, recorder, state: .init(remoteConnectionSheet: .init(hosts: [Self.box]))
    )
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: Self.box, remotePath: "/srv/app", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet = nil
    }
    #expect(recorder.added.count == 1)
    #expect(recorder.added.first?.endpoint == Self.box.endpoint)
    #expect(recorder.added.first?.path == "/srv/app")
  }

  @Test
  func connectToTheSamePathOnAnotherHostAddsAServerProject() async {
    let onMini = Project(
      name: "app", rootPath: "/srv/app", hostID: Self.mini.id, remoteHost: Self.mini.endpoint
    )
    let fake = HostListFake(hosts: [Self.box, Self.mini], projects: [onMini])
    let recorder = Recorder()
    let store = Self.makeStore(
      fake, recorder, state: .init(remoteConnectionSheet: .init(hosts: [Self.box, Self.mini]))
    )
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: Self.box, remotePath: "/srv/app", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet = nil
    }
    #expect(recorder.added.count == 1)
  }

  @Test
  func editConnectionToAnotherProjectsHostAndPathShowsAnErrorAndKeepsTheProject() async {
    let project = Project(
      name: "app", rootPath: "/srv/app", hostID: Self.box.id, remoteHost: Self.box.endpoint
    )
    let other = Project(
      name: "web", rootPath: "/srv/web", hostID: Self.mini.id, remoteHost: Self.mini.endpoint
    )
    let fake = HostListFake(hosts: [Self.box, Self.mini], projects: [project, other])
    let recorder = Recorder()
    var sheet = RemoteConnectionFeature.State.editing(project: project, hosts: [Self.box, Self.mini])
    sheet?.hostChoice = .existing(Self.mini.id)
    sheet?.pathDraft = "/srv/web/"
    let store = Self.makeStore(fake, recorder, state: .init(remoteConnectionSheet: sheet))
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: Self.mini, remotePath: "/srv/web", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet?.errorMessage =
        RemoteConnectionFeature.State.duplicateProjectMessage(name: "web", host: Self.mini)
    }
    #expect(store.state.remoteConnectionSheet != nil)
    #expect(recorder.updated.isEmpty)
  }

  @Test
  func editConnectionThatKeepsTheProjectsOwnHostAndPathSaves() async {
    let project = Project(
      name: "app", rootPath: "/srv/app", hostID: Self.box.id, remoteHost: Self.box.endpoint
    )
    // An existing duplicate is not a conflict for either of its Projects.
    let duplicate = Project(
      name: "app2", rootPath: "/srv/app", hostID: Self.box.id, remoteHost: Self.box.endpoint
    )
    let fake = HostListFake(hosts: [Self.box], projects: [duplicate, project])
    let recorder = Recorder()
    let sheet = RemoteConnectionFeature.State.editing(project: project, hosts: [Self.box])
    let store = Self.makeStore(fake, recorder, state: .init(remoteConnectionSheet: sheet))
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: Self.box, remotePath: "/srv/app", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet = nil
    }
    #expect(recorder.updated.first?.projectID == project.id)
  }

  @Test
  func editConnectionToAFreePathSaves() async {
    let project = Project(
      name: "app", rootPath: "/srv/app", hostID: Self.box.id, remoteHost: Self.box.endpoint
    )
    let local = Project(name: "web", rootPath: "/srv/web")
    let fake = HostListFake(hosts: [Self.box], projects: [project, local])
    let recorder = Recorder()
    let sheet = RemoteConnectionFeature.State.editing(project: project, hosts: [Self.box])
    let store = Self.makeStore(fake, recorder, state: .init(remoteConnectionSheet: sheet))
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: Self.box, remotePath: "/srv/web", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet = nil
    }
    #expect(recorder.updated.first?.projectID == project.id)
    #expect(recorder.updated.first?.path == "/srv/web")
  }

  @Test
  func connectWithANewHostAddsItToTheHostList() async {
    let fake = HostListFake(hosts: [Self.box])
    let recorder = Recorder()
    let newHost = HostRecord(address: "new.local", name: "New")
    let store = Self.makeStore(fake, recorder, state: .init(remoteConnectionSheet: .init()))
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: newHost, remotePath: "/srv/web", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet = nil
    }
    #expect(fake.catalog.hosts == [Self.box, newHost])
    #expect(recorder.added.first?.name == "web")
    #expect(recorder.added.first?.endpoint == newHost.endpoint)
  }

  @Test
  func connectDoesNotSaveWhenTheHostChangedWhileConnecting() async {
    // SSH validated `box`; Settings changed its address before the result
    // came back. The validated path and git root belong to the old address,
    // so nothing is saved and the sheet asks for a new check.
    var edited = Self.box
    edited.address = "10.0.0.5"
    let fake = HostListFake(hosts: [edited])
    let recorder = Recorder()
    let store = Self.makeStore(
      fake, recorder, state: .init(remoteConnectionSheet: .init(hosts: [Self.box]))
    )
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: Self.box, remotePath: "/srv/app", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet?.hosts = [edited]
      $0.remoteConnectionSheet?.errorMessage = RemoteConnectionFeature.State.hostChangedMessage
    }
    #expect(store.state.remoteConnectionSheet?.hostChoice == .existing(Self.box.id))
    #expect(recorder.added.isEmpty)
    #expect(recorder.updated.isEmpty)
    #expect(fake.catalog.hosts == [edited])
  }

  @Test
  func connectDoesNotSaveWhenThePickedHostWasDeletedWhileConnecting() async {
    let fake = HostListFake(hosts: [Self.mini])
    let recorder = Recorder()
    let store = Self.makeStore(
      fake, recorder,
      state: .init(remoteConnectionSheet: .init(hosts: [Self.box, Self.mini]))
    )
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: Self.box, remotePath: "/srv/app", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet?.hosts = [Self.mini]
      $0.remoteConnectionSheet?.hostChoice = .existing(Self.mini.id)
      $0.remoteConnectionSheet?.errorMessage = RemoteConnectionFeature.State.hostChangedMessage
    }
    // The deleted Host is not added back.
    #expect(fake.catalog.hosts == [Self.mini])
    #expect(recorder.added.isEmpty)
  }

  @Test
  func editConnectionDoesNotSaveWhenTheHostChangedWhileConnecting() async {
    let project = Project(
      name: "app", rootPath: "/srv/app", hostID: Self.box.id, remoteHost: Self.box.endpoint
    )
    var edited = Self.mini
    edited.port = 2200
    let fake = HostListFake(hosts: [Self.box, edited], projects: [project])
    let recorder = Recorder()
    let sheet = RemoteConnectionFeature.State.editing(project: project, hosts: [Self.box, Self.mini])
    let store = Self.makeStore(fake, recorder, state: .init(remoteConnectionSheet: sheet))
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: Self.mini, remotePath: "/srv/app", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet?.hosts = [Self.box, edited]
      $0.remoteConnectionSheet?.errorMessage = RemoteConnectionFeature.State.hostChangedMessage
    }
    #expect(recorder.updated.isEmpty)
  }

  @Test
  func editConnectionMovesTheProjectToAnotherHost() async {
    let project = Project(
      name: "app", rootPath: "/srv/app", hostID: Self.box.id, remoteHost: Self.box.endpoint
    )
    let fake = HostListFake(hosts: [Self.box, Self.mini], projects: [project])
    let recorder = Recorder()
    let store = Self.makeStore(fake, recorder)
    await store.send(.projectEditConnectionTapped(projectID: project.id)) {
      $0.remoteConnectionSheet = .editing(project: project, hosts: [Self.box, Self.mini])
    }
    #expect(store.state.remoteConnectionSheet?.hostChoice == .existing(Self.box.id))
    await store.send(.remoteConnectionSheet(.hostChoiceChanged(.existing(Self.mini.id))))
    await store.send(
      .remoteConnectionSheet(.delegate(.connected(host: Self.mini, remotePath: "/srv/app", gitRoot: nil)))
    ) {
      $0.remoteConnectionSheet = nil
    }
    #expect(recorder.updated.count == 1)
    #expect(recorder.updated.first?.projectID == project.id)
    #expect(recorder.updated.first?.endpoint == Self.mini.endpoint)
    // Edit Connection never changes a Host's fields.
    #expect(fake.catalog.hosts == [Self.box, Self.mini])
  }
}
