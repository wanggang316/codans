import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

/// Reducer-level coverage for `RemoteConnectionFeature`'s pure paths — draft
/// edits and the pre-flight field validation that runs *before* any SSH probe.
/// The network validation pipeline (`connectButtonTapped` → `.run`) is not
/// exercised here; it depends on a reachable host.
@MainActor
struct RemoteConnectionFeatureTests {
  @Test
  func portFieldKeepsDigitsOnly() async {
    let store = TestStore(initialState: RemoteConnectionFeature.State()) {
      RemoteConnectionFeature()
    }
    await store.send(.portChanged("2a2b2")) {
      $0.portDraft = "222"
    }
  }

  @Test
  func connectRejectsEmptyHost() async {
    let store = TestStore(initialState: RemoteConnectionFeature.State(pathDraft: "/srv/app")) {
      RemoteConnectionFeature()
    }
    // No host → validation error, no effect (no SSH probe launched).
    await store.send(.connectButtonTapped) {
      $0.errorMessage = "Enter a host or SSH alias."
    }
  }

  @Test
  func connectRejectsEmptyPath() async {
    let store = TestStore(initialState: RemoteConnectionFeature.State(hostDraft: "example.com")) {
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
        hostDraft: "example.com", portDraft: "70000", pathDraft: "/srv/app"
      )
    ) {
      RemoteConnectionFeature()
    }
    await store.send(.connectButtonTapped) {
      $0.errorMessage = "Port must be between 1 and 65535."
    }
  }

  @Test
  func editingSeedsFormFromServerProject() {
    let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)
    let project = Project(
      name: "app", rootPath: "/srv/app", gitRoot: "/srv/app", remoteHost: host
    )
    let seeded = RemoteConnectionFeature.State.editing(project: project)
    #expect(seeded?.mode == .edit(projectID: project.id))
    #expect(seeded?.isEditing == true)
    #expect(seeded?.hostDraft == "example.com")
    #expect(seeded?.portDraft == "2222")
    #expect(seeded?.usernameDraft == "alice")
    #expect(seeded?.pathDraft == "/srv/app")
    // A local project has no connection to edit.
    let local = Project(name: "local", rootPath: "/tmp/x")
    #expect(RemoteConnectionFeature.State.editing(project: local) == nil)
  }

  @Test
  func connectSucceededDelegatesConnected() async {
    let host = RemoteHost(alias: "example.com", username: "alice", port: 2222)
    let store = TestStore(initialState: RemoteConnectionFeature.State(isConnecting: true)) {
      RemoteConnectionFeature()
    }
    await store.send(.connectSucceeded(host: host, remotePath: "/srv/app", gitRoot: "/srv/app")) {
      $0.isConnecting = false
    }
    await store.receive(\.delegate.connected)
  }
}
