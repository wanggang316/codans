import Foundation
import Testing
import CodansCore
import CodansIPC

@testable import Codans

/// `ProjectHandlers.listScripts` IPC coverage. Pins the server-side contract
/// the `project commands list` CLI leaf depends on, against a live
/// `SettingsStore` + stub `HierarchyClient`:
///
/// - returns the Project's persisted scripts in stored order;
/// - reports ONLY persisted scripts — never the virtual built-in Run;
/// - empty / undefined Project → `[]`, no error;
/// - unknown ProjectID (nil `kind`) → `IPCError.notFound` (CLI exit 2).
@MainActor
struct ProjectHandlersTests {
  private func makeStore() -> SettingsStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ProjectHandlersTests-\(UUID().uuidString).json"
    )
    return SettingsStore(fileURL: url)
  }

  /// Hierarchy stub that recognizes exactly `projectID`.
  private func makeHierarchy(knowing projectID: ProjectID) -> HierarchyClient {
    var hierarchy = HierarchyClient.testValue
    hierarchy.kind = { pid in pid == projectID ? .gitRepo : nil }
    return hierarchy
  }

  @Test
  func listScriptsReturnsPersistedScriptsInStoredOrder() throws {
    let projectID = ProjectID(raw: UUID())
    let store = makeStore()
    let run = ScriptDefinition(kind: .run, command: "make run")
    let lint = ScriptDefinition(kind: .lint, name: "CI Lint", command: "swiftlint")
    store.mutateProject(projectID) { $0.scripts = [run, lint] }

    let handlers = ProjectHandlers(settings: store, hierarchy: makeHierarchy(knowing: projectID))
    let response = try handlers.listScripts(.init(projectID: projectID))

    #expect(response.scripts.map(\.id) == [run.id, lint.id])
    #expect(response.scripts.map(\.command) == ["make run", "swiftlint"])
    #expect(response.scripts[1].name == "CI Lint")
  }

  @Test
  func listScriptsDoesNotSynthesizeBuiltinRun() throws {
    // A project with NO persisted scripts must list nothing — the built-in Run
    // placeholder is a view-layer affordance, not a persisted row.
    let projectID = ProjectID(raw: UUID())
    let store = makeStore()  // never writes scripts for this project
    let handlers = ProjectHandlers(settings: store, hierarchy: makeHierarchy(knowing: projectID))

    let response = try handlers.listScripts(.init(projectID: projectID))
    #expect(response.scripts.isEmpty)
    #expect(!response.scripts.contains { $0.id == ScriptDefinition.builtinRunID })
  }

  @Test
  func listScriptsThrowsNotFoundForUnknownProject() {
    var hierarchy = HierarchyClient.testValue
    hierarchy.kind = { _ in nil }  // every ProjectID is unknown
    let handlers = ProjectHandlers(settings: makeStore(), hierarchy: hierarchy)

    #expect {
      _ = try handlers.listScripts(.init(projectID: ProjectID(raw: UUID())))
    } throws: { error in
      guard case IPCError.notFound(let kind, _) = error else { return false }
      return kind == "project"
    }
  }

  // MARK: - addScript

  @Test
  func addScriptAppendsAndReturnsEntry() throws {
    let projectID = ProjectID(raw: UUID())
    let store = makeStore()
    let handlers = ProjectHandlers(settings: store, hierarchy: makeHierarchy(knowing: projectID))

    let script = ScriptDefinition(kind: .test, name: "Unit", command: "make test")
    let response = try handlers.addScript(.init(projectID: projectID, script: script))

    #expect(response.script.id == script.id)
    #expect(store.settings.projects[projectID]?.scripts.map(\.id) == [script.id])
    #expect(store.settings.projects[projectID]?.scripts.first?.command == "make test")
  }

  @Test
  func addScriptNormalizesTargetIncompatibleOnFinished() throws {
    // newTab + closePane (a split-only action on a tab target) is normalized to
    // none — the echo and the persisted value both drop the on-finished (D13).
    let projectID = ProjectID(raw: UUID())
    let store = makeStore()
    let handlers = ProjectHandlers(settings: store, hierarchy: makeHierarchy(knowing: projectID))

    let script = ScriptDefinition(kind: .run, command: "x", target: .newTab, onFinished: .closePane)
    let response = try handlers.addScript(.init(projectID: projectID, script: script))

    #expect(response.script.onFinished == ScriptOnFinished.none)
    #expect(store.settings.projects[projectID]?.scripts.first?.onFinished == ScriptOnFinished.none)
  }

  @Test
  func addScriptRunKindKeepsRandomIDNotBuiltin() throws {
    // A user-added run-kind command keeps its own id (not the reserved built-in)
    // and is the only persisted entry — no synthesis side effect.
    let projectID = ProjectID(raw: UUID())
    let store = makeStore()
    let handlers = ProjectHandlers(settings: store, hierarchy: makeHierarchy(knowing: projectID))

    let script = ScriptDefinition(kind: .run, command: "make run")
    let response = try handlers.addScript(.init(projectID: projectID, script: script))

    #expect(response.script.id != ScriptDefinition.builtinRunID)
    #expect(store.settings.projects[projectID]?.scripts.count == 1)
  }

  @Test
  func addScriptThrowsNotFoundForUnknownProject() {
    var hierarchy = HierarchyClient.testValue
    hierarchy.kind = { _ in nil }
    let handlers = ProjectHandlers(settings: makeStore(), hierarchy: hierarchy)
    let script = ScriptDefinition(kind: .run, command: "x")
    #expect {
      _ = try handlers.addScript(.init(projectID: ProjectID(raw: UUID()), script: script))
    } throws: { error in
      guard case IPCError.notFound(let kind, _) = error else { return false }
      return kind == "project"
    }
  }

  // MARK: - updateScript

  @Test
  func updateScriptReplacesEntryByID() throws {
    let projectID = ProjectID(raw: UUID())
    let store = makeStore()
    let original = ScriptDefinition(kind: .run, name: "Old", command: "old")
    store.mutateProject(projectID) { $0.scripts = [original] }
    let handlers = ProjectHandlers(settings: store, hierarchy: makeHierarchy(knowing: projectID))

    var edited = original
    edited.name = "New"
    edited.command = "new"
    let response = try handlers.updateScript(.init(projectID: projectID, script: edited))

    #expect(response.script.id == original.id)
    #expect(store.settings.projects[projectID]?.scripts.count == 1)
    #expect(store.settings.projects[projectID]?.scripts.first?.name == "New")
    #expect(store.settings.projects[projectID]?.scripts.first?.command == "new")
  }

  @Test
  func updateScriptThrowsNotFoundForUnknownID() {
    let projectID = ProjectID(raw: UUID())
    let store = makeStore()
    store.mutateProject(projectID) { $0.scripts = [ScriptDefinition(kind: .run, command: "x")] }
    let handlers = ProjectHandlers(settings: store, hierarchy: makeHierarchy(knowing: projectID))

    let stranger = ScriptDefinition(kind: .lint, command: "y")  // a different id
    #expect {
      _ = try handlers.updateScript(.init(projectID: projectID, script: stranger))
    } throws: { error in
      guard case IPCError.notFound(let kind, _) = error else { return false }
      return kind == "command"
    }
  }

  @Test
  func updateScriptMaterializesBuiltinRun() throws {
    // Editing the reserved built-in id is allowed and writes a real entry under
    // that same id (materialization) — only removal is guarded (D14).
    let projectID = ProjectID(raw: UUID())
    let store = makeStore()
    let builtin = ScriptDefinition.builtinRun
    store.mutateProject(projectID) { $0.scripts = [builtin] }
    let handlers = ProjectHandlers(settings: store, hierarchy: makeHierarchy(knowing: projectID))

    var edited = builtin
    edited.command = "make run-custom"
    let response = try handlers.updateScript(.init(projectID: projectID, script: edited))

    #expect(response.script.id == ScriptDefinition.builtinRunID)
    #expect(store.settings.projects[projectID]?.scripts.first?.command == "make run-custom")
  }

  // MARK: - removeScript

  @Test
  func removeScriptDropsEntryByID() throws {
    let projectID = ProjectID(raw: UUID())
    let store = makeStore()
    let keep = ScriptDefinition(kind: .run, command: "keep")
    let drop = ScriptDefinition(kind: .test, command: "drop")
    store.mutateProject(projectID) { $0.scripts = [keep, drop] }
    let handlers = ProjectHandlers(settings: store, hierarchy: makeHierarchy(knowing: projectID))

    let response = try handlers.removeScript(.init(projectID: projectID, scriptID: drop.id))

    #expect(response.id == drop.id.uuidString)
    #expect(store.settings.projects[projectID]?.scripts.map(\.id) == [keep.id])
  }

  @Test
  func removeScriptRejectsBuiltinRunWithConflict() {
    let projectID = ProjectID(raw: UUID())
    let store = makeStore()
    let handlers = ProjectHandlers(settings: store, hierarchy: makeHierarchy(knowing: projectID))
    #expect {
      _ = try handlers.removeScript(
        .init(projectID: projectID, scriptID: ScriptDefinition.builtinRunID))
    } throws: { error in
      if case IPCError.conflict = error { return true }
      return false
    }
  }

  @Test
  func removeScriptThrowsNotFoundForUnknownID() {
    let projectID = ProjectID(raw: UUID())
    let store = makeStore()
    store.mutateProject(projectID) { $0.scripts = [ScriptDefinition(kind: .run, command: "x")] }
    let handlers = ProjectHandlers(settings: store, hierarchy: makeHierarchy(knowing: projectID))
    #expect {
      _ = try handlers.removeScript(.init(projectID: projectID, scriptID: UUID()))
    } throws: { error in
      guard case IPCError.notFound(let kind, _) = error else { return false }
      return kind == "command"
    }
  }
}
