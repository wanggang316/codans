import ComposableArchitecture
import Foundation
import Testing
import CodansCore

@testable import Codans

@MainActor
struct WorktreeHeaderCommandSuggestionTests {
  private nonisolated static let source = CommandSuggestionSource(id: "package-json", displayName: "package.json")
  private nonisolated static let build = CommandSuggestion(source: source, name: "build", command: "pnpm run build")
  private nonisolated static let group = CommandSuggestionGroup(source: source, suggestions: [build])

  @Test
  func scanStoresGroupsForTheScannedWorktree() async {
    let worktree = Worktree(name: "feat", path: "/repo/.worktrees/feat")
    let project = Project(name: "repo", rootPath: "/repo", worktrees: [worktree])
    let scanned = LockIsolated<[ManifestLocation]>([])
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.snapshot = { Catalog(projects: [project]) }
      $0.commandSuggestionClient.scan = { location in
        scanned.withValue { $0.append(location) }
        return [Self.group]
      }
    }

    await store.send(.scanCommandSuggestions(projectID: project.id, worktreeID: worktree.id)) {
      $0.commandSuggestionsWorktreeID = worktree.id
      $0.isScanningCommandSuggestions = true
    }
    await store.receive(\.commandSuggestionsScanned) {
      $0.commandSuggestions = [Self.group]
      $0.isScanningCommandSuggestions = false
    }
    // The header scans the worktree it shows, not the Project's selection.
    #expect(scanned.value == [ManifestLocation(directory: "/repo/.worktrees/feat", host: nil)])
  }

  @Test
  func switchingWorktreeClearsTheListAndDropsALateResult() async {
    let first = WorktreeID()
    var state = WorktreeHeaderFeature.State()
    state.commandSuggestions = [Self.group]
    state.commandSuggestionsWorktreeID = first
    let second = Worktree(name: "b", path: "/repo/b")
    let project = Project(name: "repo", rootPath: "/repo", worktrees: [second])
    let store = TestStore(initialState: state) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0.hierarchyClient = .testValue
      $0.hierarchyClient.snapshot = { Catalog(projects: [project]) }
      $0.commandSuggestionClient.scan = { _ in [] }
    }

    await store.send(.scanCommandSuggestions(projectID: project.id, worktreeID: second.id)) {
      $0.commandSuggestions = []
      $0.commandSuggestionsWorktreeID = second.id
      $0.isScanningCommandSuggestions = true
    }
    await store.receive(\.commandSuggestionsScanned) {
      $0.isScanningCommandSuggestions = false
    }
    // A result for the worktree the header already left must not land.
    await store.send(.commandSuggestionsScanned(worktreeID: first, [Self.group]))
  }

  @Test
  func addAdoptsIntoProjectScriptsWithoutRunning() async {
    let projectID = ProjectID()
    let written = LockIsolated<[ScriptDefinition]?>(nil)
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0.settingsWriter = .testValue
      $0.settingsWriter.readSnapshotSync = { Settings() }
      $0.settingsWriter.setProjectScripts = { pid, scripts in
        #expect(pid == projectID)
        written.setValue(scripts)
      }
    }

    // No delegate is received: adding never routes to the run path.
    await store.send(.addCommandSuggestionTapped(projectID: projectID, Self.build))
    await store.finish()
    #expect(written.value?.map(\.command) == ["pnpm run build"])
    #expect(written.value?.first?.systemImage == "hammer.fill")
  }

  @Test
  func addingAnAlreadyAdoptedCommandWritesNothing() async {
    let projectID = ProjectID()
    let settings = Settings(
      projects: [projectID: ProjectSettings(scripts: [ScriptDefinition(kind: .custom, command: "pnpm run build")])])
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0.settingsWriter = .testValue
      $0.settingsWriter.readSnapshotSync = { settings }
    }

    // `setProjectScripts` stays unimplemented: any write would fail the test.
    await store.send(.addCommandSuggestionTapped(projectID: projectID, Self.build))
  }

  @Test
  func runningAnAdoptedSuggestionRunsTheSavedScript() async {
    let projectID = ProjectID()
    let saved = ScriptDefinition(kind: .custom, command: "pnpm run build")
    let settings = Settings(projects: [projectID: ProjectSettings(scripts: [saved])])
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0.settingsWriter = .testValue
      $0.settingsWriter.readSnapshotSync = { settings }
    }

    await store.send(.runCommandSuggestionTapped(projectID: projectID, Self.build))
    await store.receive(.delegate(.runScriptRequested(scriptID: saved.id)))
  }

  @Test
  func runningANewSuggestionRunsATransientScriptWithAStableID() async {
    let store = TestStore(initialState: WorktreeHeaderFeature.State()) {
      WorktreeHeaderFeature()
    } withDependencies: {
      $0.settingsWriter = .testValue
      $0.settingsWriter.readSnapshotSync = { Settings() }
    }

    let expected = CommandSuggestionAdoption.transientScript(for: Self.build)
    await store.send(.runCommandSuggestionTapped(projectID: ProjectID(), Self.build))
    await store.receive(.delegate(.runCommandRequested(expected)))
    #expect(expected.command == "pnpm run build")
  }
}
