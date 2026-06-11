import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct ProjectSettingsFeatureTests {
  // MARK: - setDefaultEditorOverride

  @Test
  func setDefaultEditorOverrideForwardsToSettingsWriter() async {
    let projectID = ProjectID()
    let captured = LockIsolated<(ProjectID, EditorID?)?>(nil)
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: projectID)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectDefaultEditor = { pid, eid in
        captured.setValue((pid, eid))
      }
    }

    await store.send(.setDefaultEditorOverride("vscode"))
    await store.receive(\.writeFailed)
    #expect(captured.value?.0 == projectID)
    #expect(captured.value?.1 == "vscode")
  }

  @Test
  func setDefaultEditorOverridePassesNilForClearRequest() async {
    let captured = LockIsolated<EditorID??>(nil)
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: ProjectID())) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectDefaultEditor = { _, eid in
        captured.setValue(.some(eid))
      }
    }

    await store.send(.setDefaultEditorOverride(nil))
    await store.receive(\.writeFailed)
    #expect(captured.value == .some(nil))
  }

  @Test
  func setDefaultEditorOverrideClearsLastWriteFailureOnSuccess() async {
    var initial = ProjectSettingsFeature.State(projectID: ProjectID())
    initial.lastWriteFailure = "previous error"
    let store = TestStore(initialState: initial) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectDefaultEditor = { _, _ in }
    }

    await store.send(.setDefaultEditorOverride("xcode"))
    await store.receive(\.writeFailed) {
      $0.lastWriteFailure = nil
    }
  }

  // MARK: - setWorktreeBaseDirectory

  @Test
  func setWorktreeBaseDirectoryForwardsToSettingsWriter() async {
    let projectID = ProjectID()
    let captured = LockIsolated<(ProjectID, String?)?>(nil)
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: projectID)) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectWorktreesDirectory = { pid, path in
        captured.setValue((pid, path))
      }
    }

    await store.send(.setWorktreeBaseDirectory("/Users/me/worktrees"))
    await store.receive(\.writeFailed)
    #expect(captured.value?.0 == projectID)
    #expect(captured.value?.1 == "/Users/me/worktrees")
  }

  @Test
  func setWorktreeBaseDirectoryPassesNilForClearRequest() async {
    let captured = LockIsolated<String??>(nil)
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: ProjectID())) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectWorktreesDirectory = { _, path in
        captured.setValue(.some(path))
      }
    }

    await store.send(.setWorktreeBaseDirectory(nil))
    await store.receive(\.writeFailed)
    #expect(captured.value == .some(nil))
  }

  // MARK: - writeFailed

  @Test
  func writeFailedEmptyStringClearsError() async {
    var initial = ProjectSettingsFeature.State(projectID: ProjectID())
    initial.lastWriteFailure = "something"
    let store = TestStore(initialState: initial) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.finderClient = .testValue
    }

    await store.send(.writeFailed("")) {
      $0.lastWriteFailure = nil
    }
  }

  @Test
  func writeFailedNonEmptyRecordsMessage() async {
    let store = TestStore(initialState: ProjectSettingsFeature.State(projectID: ProjectID())) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.finderClient = .testValue
    }

    await store.send(.writeFailed("io error")) {
      $0.lastWriteFailure = "io error"
    }
  }
}
