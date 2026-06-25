import Foundation
import CodansCore
import CodansIPC

/// Server-side handler for the `project.*` IPC surface — per-Project settings
/// that live in `settings.json` (owned by `SettingsStore`), distinct from the
/// catalog-backed `hierarchy.*` namespace.
///
/// Modeled on `EditorHandlers`: it holds a `SettingsStore` (the persisted
/// truth) plus a `HierarchyClient` used only to validate that a `ProjectID`
/// refers to a registered Project before reading its settings. Reading
/// `settings.projects[id]` directly would silently return `[]` for a bogus
/// id; the existence check turns that into a `notFound` the CLI maps to
/// exit 2.
///
/// This is the spine for the Commands CLI group: `listScripts` is the first
/// method; add/remove/edit reuse the same store + validation pattern.
@MainActor
final class ProjectHandlers {
  private let settings: SettingsStore
  private let hierarchy: HierarchyClient

  init(settings: SettingsStore, hierarchy: HierarchyClient) {
    self.settings = settings
    self.hierarchy = hierarchy
  }

  // MARK: - listScripts

  /// `project.listScripts` — return the Project's persisted scripts in stored
  /// order. Reports ONLY what is on disk: the virtual built-in Run placeholder
  /// is a view-layer affordance and is never synthesized here.
  func listScripts(_ request: ListScriptsRequest) throws -> ListScriptsResponse {
    let projectID = request.projectID
    // Mirror `EditorHandlers.setProjectDefault`: validate against the catalog
    // snapshot before reading so an unknown id surfaces as `notFound` rather
    // than an empty-scripts husk.
    guard hierarchy.kind(projectID) != nil else {
      throw IPCError.notFound(kind: "project", id: projectID.description)
    }
    let scripts = settings.settings.projects[projectID]?.scripts ?? []
    return ListScriptsResponse(scripts: scripts)
  }

  // MARK: - Wire types

  /// Params for `project.listScripts`. Reuses `ProjectID` directly — it is a
  /// `public Codable` in `CodansCore`. Inlined here (matching how the
  /// hierarchy handlers inline their request/response shapes) rather than
  /// promoted to `CodansIPC`.
  struct ListScriptsRequest: Codable, Sendable {
    let projectID: ProjectID
  }

  /// Result for `project.listScripts`. Carries `ScriptDefinition` on the wire
  /// (its `Codable` is the same omit-when-default shape `settings.json` uses).
  /// The CLI re-projects this into a stable-key `ScriptDefinitionDTO` for
  /// `--json`; the server stays faithful to the domain model.
  struct ListScriptsResponse: Codable, Sendable {
    let scripts: [ScriptDefinition]
  }
}
