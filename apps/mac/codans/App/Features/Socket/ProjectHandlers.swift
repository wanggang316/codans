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

  // MARK: - addScript / updateScript / removeScript

  /// `project.addScript` — append a new script and return the stored
  /// (normalized) entry. Flushes synchronously (D18) so a CLI read-after-write
  /// observes it without the SettingsStore debounce window.
  func addScript(_ request: AddScriptRequest) throws -> ScriptResponse {
    let projectID = request.projectID
    guard hierarchy.kind(projectID) != nil else {
      throw IPCError.notFound(kind: "project", id: projectID.description)
    }
    let normalized = try Self.normalize(request.script)
    settings.mutateProject(projectID) { $0.scripts.append(normalized) }
    try settings.saveNow()
    return ScriptResponse(script: normalized)
  }

  /// `project.updateScript` — replace the entry whose id matches by value.
  /// Unknown id (in this Project) → `notFound`. Editing the built-in Run id is
  /// allowed (it materializes the entry); only removal is guarded.
  func updateScript(_ request: UpdateScriptRequest) throws -> ScriptResponse {
    let projectID = request.projectID
    guard hierarchy.kind(projectID) != nil else {
      throw IPCError.notFound(kind: "project", id: projectID.description)
    }
    let current = settings.settings.projects[projectID]?.scripts ?? []
    guard current.contains(where: { $0.id == request.script.id }) else {
      throw IPCError.notFound(kind: "command", id: request.script.id.uuidString)
    }
    let normalized = try Self.normalize(request.script)
    settings.mutateProject(projectID) { entry in
      if let idx = entry.scripts.firstIndex(where: { $0.id == normalized.id }) {
        entry.scripts[idx] = normalized
      }
    }
    try settings.saveNow()
    return ScriptResponse(script: normalized)
  }

  /// `project.removeScript` — drop the entry by id. The reserved built-in Run
  /// id is rejected with `conflict` (D14: it can be customized but never
  /// removed, preserving the GUI's reset invariant). Unknown id → `notFound`.
  func removeScript(_ request: RemoveScriptRequest) throws -> RemoveScriptResponse {
    let projectID = request.projectID
    guard hierarchy.kind(projectID) != nil else {
      throw IPCError.notFound(kind: "project", id: projectID.description)
    }
    guard request.scriptID != ScriptDefinition.builtinRunID else {
      throw IPCError.conflict(
        reason: "the built-in Run command cannot be removed; it can only be customized"
      )
    }
    let current = settings.settings.projects[projectID]?.scripts ?? []
    guard current.contains(where: { $0.id == request.scriptID }) else {
      throw IPCError.notFound(kind: "command", id: request.scriptID.uuidString)
    }
    settings.mutateProject(projectID) { entry in
      entry.scripts.removeAll { $0.id == request.scriptID }
    }
    try settings.saveNow()
    return RemoveScriptResponse(id: request.scriptID.uuidString)
  }

  /// Round-trip a script through `ScriptDefinition`'s own omit-when-default,
  /// target-gated `Codable` so the persisted in-memory value, the on-disk
  /// bytes, and the echo all agree — e.g. a `closePane` on-finished on a
  /// `newTab` target is dropped to `.none` (D13). Mirrors what reloading
  /// `settings.json` would yield, without a disk round-trip.
  private static func normalize(_ script: ScriptDefinition) throws -> ScriptDefinition {
    let data = try JSONEncoder().encode(script)
    return try JSONDecoder().decode(ScriptDefinition.self, from: data)
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

  /// Params for `project.addScript`. The CLI builds the full `ScriptDefinition`
  /// (minting the id); the server normalizes + appends it.
  struct AddScriptRequest: Codable, Sendable {
    let projectID: ProjectID
    let script: ScriptDefinition
  }

  /// Params for `project.updateScript`. `script.id` selects the entry to
  /// replace; the CLI overlays only the user-supplied fields before sending.
  struct UpdateScriptRequest: Codable, Sendable {
    let projectID: ProjectID
    let script: ScriptDefinition
  }

  /// Params for `project.removeScript`.
  struct RemoveScriptRequest: Codable, Sendable {
    let projectID: ProjectID
    let scriptID: UUID
  }

  /// Result for add / update — the stored (normalized) entry, which the CLI
  /// re-projects into the stable-key `ScriptDefinitionDTO` for `--json`.
  struct ScriptResponse: Codable, Sendable {
    let script: ScriptDefinition
  }

  /// Result for remove — the id that was dropped.
  struct RemoveScriptResponse: Codable, Sendable {
    let id: String
  }
}
