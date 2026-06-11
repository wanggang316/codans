import ComposableArchitecture
import Dependencies
import Foundation
import Testing
import CodansCore

@testable import Codans

/// M10 coverage: `CommandPaletteItems.build` surfaces one `runProjectScript`
/// item per active-Project script, the items track active-selection
/// switches, and `RootFeature` routes activation into
/// `HierarchyClient.runScript`.
@MainActor
struct CommandPaletteRunScriptTests {

  // MARK: - Builder

  @Test
  func buildEmitsOneItemPerProjectScriptInOrder() {
    var catalog = Catalog()
    var project = Project(name: "P", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    let worktree = Worktree(name: "wt", path: "/tmp/p/wt", branch: "main")
    project.worktrees = [worktree]
    catalog.projects = [project]
    let selection = HierarchySelection(
      projectID: project.id, worktreeID: worktree.id
    )

    let scripts = [
      ScriptDefinition(kind: .test, name: "Run unit tests", command: "swift test"),
      ScriptDefinition(kind: .deploy, name: "Ship to staging", command: "make deploy"),
      ScriptDefinition(kind: .custom, name: "Tail logs", command: "tail -f log"),
    ]
    let settings: Settings = {
      var s = Settings()
      s.projects[project.id] = ProjectSettings(scripts: scripts)
      return s
    }()

    let items = withDependencies {
      $0[SettingsWriter.self].readSnapshotSync = { settings }
    } operation: {
      CommandPaletteItems.build(selection: selection, catalog: catalog)
    }

    let scriptItems = items.filter {
      if case .runProjectScript = $0.kind { return true }
      return false
    }
    #expect(scriptItems.count == 3)
    #expect(scriptItems.map(\.title) == ["Run unit tests", "Ship to staging", "Tail logs"])
    #expect(scriptItems.map(\.subtitle) == ["Test", "Deploy", "Custom"])
    // Each emitted Kind carries the matching scriptID in array-stored order.
    let kindScriptIDs = scriptItems.compactMap { item -> UUID? in
      if case .runProjectScript(_, _, let id) = item.kind { return id }
      return nil
    }
    #expect(kindScriptIDs == scripts.map(\.id))
  }

  @Test
  func switchingActiveProjectSurfacesTheNewProjectsScripts() {
    var catalog = Catalog()
    var projectA = Project(name: "A", rootPath: "/tmp/a", gitRoot: "/tmp/a")
    let worktreeA = Worktree(name: "wt-a", path: "/tmp/a/wt", branch: "main")
    projectA.worktrees = [worktreeA]
    var projectB = Project(name: "B", rootPath: "/tmp/b", gitRoot: "/tmp/b")
    let worktreeB = Worktree(name: "wt-b", path: "/tmp/b/wt", branch: "main")
    projectB.worktrees = [worktreeB]
    catalog.projects = [projectA, projectB]

    let scriptA = ScriptDefinition(kind: .test, name: "Test A", command: "a")
    let scriptB = ScriptDefinition(kind: .deploy, name: "Deploy B", command: "b")
    let settings: Settings = {
      var s = Settings()
      s.projects[projectA.id] = ProjectSettings(scripts: [scriptA])
      s.projects[projectB.id] = ProjectSettings(scripts: [scriptB])
      return s
    }()

    func itemsFor(_ selection: HierarchySelection) -> [CommandPaletteItem] {
      withDependencies {
        $0[SettingsWriter.self].readSnapshotSync = { settings }
      } operation: {
        CommandPaletteItems.build(selection: selection, catalog: catalog)
      }
    }

    let selectionA = HierarchySelection(
      projectID: projectA.id, worktreeID: worktreeA.id
    )
    let selectionB = HierarchySelection(
      projectID: projectB.id, worktreeID: worktreeB.id
    )

    let titlesA = itemsFor(selectionA).filter {
      if case .runProjectScript = $0.kind { return true }
      return false
    }.map(\.title)
    let titlesB = itemsFor(selectionB).filter {
      if case .runProjectScript = $0.kind { return true }
      return false
    }.map(\.title)

    #expect(titlesA == ["Test A"])
    #expect(titlesB == ["Deploy B"])
  }

  @Test
  func buildEmitsNoScriptItemsWhenActiveProjectHasNoScripts() {
    var catalog = Catalog()
    var project = Project(name: "P", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    let worktree = Worktree(name: "wt", path: "/tmp/p/wt", branch: "main")
    project.worktrees = [worktree]
    catalog.projects = [project]
    let selection = HierarchySelection(
      projectID: project.id, worktreeID: worktree.id
    )

    let items = withDependencies {
      $0[SettingsWriter.self].readSnapshotSync = { Settings() }
    } operation: {
      CommandPaletteItems.build(selection: selection, catalog: catalog)
    }

    let scriptItems = items.filter {
      if case .runProjectScript = $0.kind { return true }
      return false
    }
    #expect(scriptItems.isEmpty)
  }

  // MARK: - Activation

  @Test
  func activateRunProjectScriptDispatchesHierarchyClient() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let scriptID = UUID()
    let captured = LockIsolated<(UUID, ProjectID, WorktreeID)?>(nil)

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.hierarchyClient.runScript = { sid, pid, wid in
        captured.setValue((sid, pid, wid))
      }
      $0.editorClient = EditorClient.testValue
      $0.gitService = GitServiceClient.testValue
    }
    store.exhaustivity = .off

    await store.send(.commandPaletteToggle(nil))
    await store.send(
      .commandPalette(
        .presented(.delegate(.activate(.runProjectScript(projectID, worktreeID, scriptID))))
      )
    )
    await store.finish()

    #expect(captured.value?.0 == scriptID)
    #expect(captured.value?.1 == projectID)
    #expect(captured.value?.2 == worktreeID)
  }

  @Test
  func activateRunProjectScriptUnknownScriptSurfacesWarningToast() async {
    let projectID = ProjectID()
    let worktreeID = WorktreeID()
    let scriptID = UUID()

    let store = TestStore(initialState: RootFeature.State()) {
      RootFeature()
    } withDependencies: {
      $0.terminalClient.events = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.selectionChanges = { AsyncStream { $0.finish() } }
      $0.hierarchyClient.snapshot = { Catalog() }
      $0.hierarchyClient.runScript = { _, _, _ in
        throw RunScriptError.unknownScript(scriptID)
      }
      $0.editorClient = EditorClient.testValue
      $0.gitService = GitServiceClient.testValue
      // The warning toast routes through StatusBarFeature whose auto-clear timer
      // consumes the continuous clock.
      $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off

    await store.send(.commandPaletteToggle(nil))
    await store.send(
      .commandPalette(
        .presented(.delegate(.activate(.runProjectScript(projectID, worktreeID, scriptID))))
      )
    )
    await store.receive(\.statusBar.push)
  }
}
