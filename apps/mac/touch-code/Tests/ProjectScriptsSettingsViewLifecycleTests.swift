import ComposableArchitecture
import Foundation
import Testing
import TouchCodeCore

@testable import TouchCode

/// Reducer-level coverage for the worktree-lifecycle script writes. The
/// editors live at the bottom of the General pane, but the write path is the
/// shared `ProjectSettingsFeature.setLifecycleScript` action — exercised here
/// against a `TestStore` so the routing is pinned without a SwiftUI view tree.
@MainActor
struct ProjectScriptsSettingsViewLifecycleTests {

  @Test
  func setLifecycleScriptForwardsToWriterForEachPhase() async {
    let projectID = ProjectID()
    let captured = LockIsolated<[(ProjectID, SettingsWriter.WorktreeLifecycle, String)]>([])
    let store = TestStore(
      initialState: ProjectSettingsFeature.State(projectID: projectID, kind: .gitRepo)
    ) {
      ProjectSettingsFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.finderClient = .testValue
      $0.settingsWriter = .testValue
      $0.settingsWriter.setProjectLifecycleScript = { pid, phase, command in
        captured.withValue { $0.append((pid, phase, command)) }
      }
    }

    await store.send(.setLifecycleScript(.setup, "npm install"))
    await store.receive(\.writeFailed)
    await store.send(.setLifecycleScript(.archive, "tar -czf /tmp/wt.tgz ."))
    await store.receive(\.writeFailed)
    await store.send(.setLifecycleScript(.delete, "./scripts/save.sh"))
    await store.receive(\.writeFailed)

    let writes = captured.value
    #expect(writes.count == 3)
    #expect(writes[0].0 == projectID)
    #expect(writes[0].1 == .setup)
    #expect(writes[0].2 == "npm install")
    #expect(writes[1].1 == .archive)
    #expect(writes[1].2 == "tar -czf /tmp/wt.tgz .")
    #expect(writes[2].1 == .delete)
    #expect(writes[2].2 == "./scripts/save.sh")
  }
}
