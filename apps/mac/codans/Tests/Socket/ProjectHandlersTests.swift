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
}
