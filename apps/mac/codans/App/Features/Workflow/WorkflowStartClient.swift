import CodansCore
import ComposableArchitecture
import Foundation

/// TCA seam between the workflow start panel (and the Command Palette rows
/// that open it) and the app-owned workflow machinery: discovery, the same
/// `WorkflowAdmission` the `workflow.*` IPC handlers use, the engine, and
/// the trust grant. The panel never reaches past this — admission stays the
/// single place that decides whether a run may start.
nonisolated struct WorkflowStartClient: Sendable {
  /// One agent pane offered to a `pick` role.
  struct PaneChoice: Equatable, Sendable, Identifiable {
    let id: PaneID
    /// `p<n> · <tab>`, the same handle the CLI prints.
    let label: String
    let agent: AgentKind
  }

  /// Definitions visible to a worktree (bundle + user + that worktree's
  /// repository scope), shadowing resolved. `nil` lists the two global
  /// scopes only.
  var catalog: @MainActor @Sendable (_ worktreePath: String?) -> [WorkflowCatalogEntry] = { _ in [] }
  var workflowSettings: @MainActor @Sendable () -> WorkflowSettings = { .default }
  var agentSettings: @MainActor @Sendable () -> AgentSettings = { .default }
  /// Agent panes in a worktree that no run has claimed yet.
  var freeAgentPanes: @MainActor @Sendable (_ worktreeID: WorktreeID) -> [PaneChoice] = { _ in [] }
  /// One pane, when it lives in `worktreeID` and runs a recognized agent.
  /// A pane already taking part in a run still answers here: admission is
  /// the one that says `PANE_BUSY`, and it says it better than a blank row.
  var agentPane: @MainActor @Sendable (_ paneID: PaneID, _ worktreeID: WorktreeID) -> PaneChoice? = { _, _ in nil }
  var admit: @MainActor @Sendable (WorkflowAdmission.Request) throws -> WorkflowAdmission.Admitted
  var start: @MainActor @Sendable (WorkflowRunConfiguration, WorkflowCatalogEntry) async throws -> UUID
  /// Records the user's agreement to run a repository file's shell steps.
  /// Only the panel calls this; the CLI can never grant trust (D8).
  var trust: @MainActor @Sendable (_ path: String, _ sha256: String) -> Void
}

extension WorkflowStartClient {
  @MainActor
  static func live(
    discovery: WorkflowDiscovery,
    admission: WorkflowAdmission,
    engine: WorkflowEngine,
    settings: SettingsStore,
    registry: WorkflowActivationRegistry,
    catalog: @escaping @MainActor @Sendable () -> Catalog,
    paneHandles: @escaping @MainActor @Sendable () -> [PaneID: Int],
    agentKind: @escaping @MainActor @Sendable (PaneID) -> AgentKind?
  ) -> WorkflowStartClient {
    WorkflowStartClient(
      catalog: { worktreePath in
        discovery.catalog(worktreeRoot: worktreePath.map { URL(fileURLWithPath: $0, isDirectory: true) })
      },
      workflowSettings: { settings.settings.workflows },
      agentSettings: { settings.settings.agents },
      freeAgentPanes: { worktreeID in
        Self.agentPanes(
          in: worktreeID, catalog: catalog(), handles: paneHandles(), agentKind: agentKind,
          isFree: { registry.runID(forPane: $0) == nil })
      },
      agentPane: { paneID, worktreeID in
        Self.agentPanes(
          in: worktreeID, catalog: catalog(), handles: paneHandles(), agentKind: agentKind,
          isFree: { _ in true }
        )
        .first { $0.id == paneID }
      },
      admit: { try admission.admit($0) },
      start: { configuration, entry in
        try await engine.start(configuration: configuration, entry: entry).runID
      },
      trust: { path, sha256 in
        settings.mutateWorkflows { $0.trust(path: path, sha256: sha256, at: Date()) }
      }
    )
  }

  /// Agent panes of one worktree, labelled with the `p<n>` handle the CLI
  /// prints so the picker and `codans tree` name the same pane.
  private static func agentPanes(
    in worktreeID: WorktreeID,
    catalog: Catalog,
    handles: [PaneID: Int],
    agentKind: @MainActor (PaneID) -> AgentKind?,
    isFree: (PaneID) -> Bool
  ) -> [PaneChoice] {
    var choices: [PaneChoice] = []
    for project in catalog.projects {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID }) else { continue }
      for tab in worktree.tabs {
        for pane in tab.panes {
          guard let kind = agentKind(pane.id), isFree(pane.id) else { continue }
          let handle = handles[pane.id].map { "p\($0)" } ?? String(pane.id.raw.uuidString.prefix(8))
          choices.append(PaneChoice(id: pane.id, label: "\(handle) · \(tab.name)", agent: kind))
        }
      }
    }
    return choices
  }
}

extension WorkflowStartClient: DependencyKey {
  /// The read closures keep their empty defaults so a build without the
  /// engine (previews, the Command Palette under test) simply offers no
  /// workflows instead of trapping.
  static let liveValue = WorkflowStartClient(
    admit: { _ in fatalError("WorkflowStartClient.liveValue not configured") },
    start: { _, _ in fatalError("WorkflowStartClient.liveValue not configured") },
    trust: { _, _ in fatalError("WorkflowStartClient.liveValue not configured") }
  )

  static let testValue = WorkflowStartClient(
    admit: unimplemented("WorkflowStartClient.admit"),
    start: unimplemented("WorkflowStartClient.start"),
    trust: unimplemented("WorkflowStartClient.trust")
  )
}
