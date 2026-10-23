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
    let id: ContentID
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
  var agentPane: @MainActor @Sendable (_ contentID: ContentID, _ worktreeID: WorktreeID) -> PaneChoice? = { _, _ in nil }
  var admit: @MainActor @Sendable (WorkflowAdmission.Request) throws -> WorkflowAdmission.Admitted
  var start: @MainActor @Sendable (WorkflowRunConfiguration, WorkflowCatalogEntry) async throws -> UUID
  /// Records the user's agreement to run a repository file's shell steps.
  /// Only the panel calls this; the CLI can never grant trust (D8).
  var trust: @MainActor @Sendable (_ path: String, _ sha256: String) -> Void
  /// Asks Settings → Workflows to open its New Workflow sheet the next time
  /// it is on screen — the toolbar menu's "New Workflow…".
  var requestNewWorkflow: @MainActor @Sendable () -> Void = {}
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
    workflowCatalog: WorkflowCatalogStore,
    paneHandles: @escaping @MainActor @Sendable () -> [ContentID: Int],
    agentKind: @escaping @MainActor @Sendable (ContentID) -> AgentKind?
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
          isFree: { registry.runID(forContent: $0) == nil })
      },
      agentPane: { contentID, worktreeID in
        Self.agentPanes(
          in: worktreeID, catalog: catalog(), handles: paneHandles(), agentKind: agentKind,
          isFree: { _ in true }
        )
        .first { $0.id == contentID }
      },
      admit: { try admission.admit($0) },
      start: { configuration, entry in
        try await engine.start(configuration: configuration, entry: entry).runID
      },
      trust: { path, sha256 in
        settings.mutateWorkflows { $0.trust(path: path, sha256: sha256, at: Date()) }
      },
      requestNewWorkflow: { [weak workflowCatalog] in workflowCatalog?.requestNewWorkflow() }
    )
  }

  /// Agent panes of one worktree, labelled with the `p<n>` handle the CLI
  /// prints so the picker and `codans tree` name the same pane.
  private static func agentPanes(
    in worktreeID: WorktreeID,
    catalog: Catalog,
    handles: [ContentID: Int],
    agentKind: @MainActor (ContentID) -> AgentKind?,
    isFree: (ContentID) -> Bool
  ) -> [PaneChoice] {
    var choices: [PaneChoice] = []
    for project in catalog.projects {
      guard let worktree = project.worktrees.first(where: { $0.id == worktreeID }) else { continue }
      for tab in worktree.allTabs {
        let contentID = tab.contentID
        guard let kind = agentKind(contentID), isFree(contentID) else { continue }
        let handle = handles[contentID].map { "p\($0)" } ?? String(contentID.raw.uuidString.prefix(8))
        let title = [tab.name, tab.cachedDisplayTitle].compactMap { $0 }.first { !$0.isEmpty }
        let label = title.map { "\(handle) · \($0)" } ?? handle
        choices.append(PaneChoice(id: contentID, label: label, agent: kind))
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
