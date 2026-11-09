import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

/// A Project has one Settings page. "Manage Project Commands…" selects it and asks the
/// page to scroll to its Commands section; the catalog dropping the Project
/// clears the selection.
@MainActor
struct SettingsWindowFeatureTests {
  @Test
  func projectCommandsRequestSelectsTheProjectPageAndRevealsCommands() async {
    let projectID = ProjectID()
    let store = TestStore(initialState: SettingsWindowFeature.State()) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.hierarchyClient.kind = { _ in .dir }
    }

    await store.send(.projectCommandsRequested(projectID)) {
      $0.selection = .project(projectID)
      var pane = ProjectSettingsFeature.State(projectID: projectID, kind: .dir)
      pane.revealsCommands = true
      $0.projectPanes = [pane]
    }
    await store.send(.projectPanes(.element(id: projectID, action: .commandsRevealed))) {
      $0.projectPanes[id: projectID]?.revealsCommands = false
    }
  }

  @Test
  func droppingTheSelectedProjectClearsTheSelection() async {
    let kept = ProjectID()
    let dropped = ProjectID()
    let store = TestStore(
      initialState: SettingsWindowFeature.State(
        selection: .project(dropped),
        projectPanes: [
          ProjectSettingsFeature.State(projectID: kept, kind: .dir),
          ProjectSettingsFeature.State(projectID: dropped, kind: .dir),
        ]
      )
    ) {
      SettingsWindowFeature()
    } withDependencies: {
      $0.hierarchyClient.kind = { _ in .dir }
    }

    await store.send(.projectsChanged([kept])) {
      $0.selection = nil
      $0.projectPanes = [ProjectSettingsFeature.State(projectID: kept, kind: .dir)]
    }
  }
}
