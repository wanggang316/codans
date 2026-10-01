import CodansCore
import Foundation

extension AgentRecoveryRunner {
  /// Capture against an already established binding. A new process can never
  /// acquire an old error merely by appearing in the current foreground group.
  static func liveTargets(
    manager: HierarchyManager, engine: TerminalEngine, registry: AgentStateStore,
    inputCoordinator: PaneInputCoordinator
  ) -> [Target] {
    var result: [Target] = []
    for project in manager.catalog.projects where !project.isRemote {
      for worktree in project.worktrees where !worktree.archived {
        for tab in worktree.tabs {
          for pane in tab.panes {
            guard let initial = registry.entries[pane.id], let binding = initial.binding else { continue }
            // Catalog and verified binding updates can arrive on separate ticks.
            // Keep the paused target so session enrichment cannot refill its budget.
            let metadataMatches = pane.agentKind == binding.kind && pane.agentSessionID == binding.sessionID
            if metadataMatches, let snapshot = engine.captureAgentSnapshot(binding: binding) {
              registry.onTerminalEvent(.paneAgentSnapshot(snapshot))
              if case .prompt(let content) = registry.entries[pane.id]?.observation?.inputAvailability {
                inputCoordinator.observePrompt(content, in: pane.id)
              }
            } else {
              registry.onBindingValidityChanged(paneID: pane.id, valid: false)
            }
            guard let entry = registry.entries[pane.id], entry.binding == binding else { continue }
            result.append(
              Target(
                binding: binding, externalInputRevision: entry.externalInputRevision,
                directory: URL(fileURLWithPath: worktree.path), observation: entry.observation,
                identityIsValid: entry.bindingIsValid, isSuppressed: entry.recoverySuppressed,
                hasResidualDraft: inputCoordinator.hasResidualDraft(in: pane.id)))
          }
        }
      }
    }
    return result
  }
}
