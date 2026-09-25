import CodansCore
import Foundation

extension AgentRecoveryRunner {
  /// A live local surface is necessary but not sufficient: the catalog binding
  /// must still match the observed Agent. Remote worktree paths are never used
  /// as local script directories.
  static func liveTargets(
    manager: HierarchyManager,
    engine: TerminalEngine,
    registry: AgentStateStore
  ) -> [Target] {
    var result: [Target] = []
    for project in manager.catalog.projects where !project.isRemote {
      for worktree in project.worktrees where !worktree.archived {
        for tab in worktree.tabs {
          for pane in tab.panes {
            guard let entry = registry.entries[pane.id],
              entry.kind == .codex || entry.kind == .claudeCode,
              !entry.recoverySuppressed,
              pane.agentKind == entry.kind,
              pane.agentSessionID == entry.sessionID,
              let surface = engine.ghosttyRuntime?.surface(for: pane.id)
            else { continue }
            let groupID = ForegroundJobReader().resolveProcessGroupID(
              preferred: surface.foregroundProcessGroupID(), childPID: surface.childProcessID()
            )
            let job = groupID.flatMap { ForegroundJobReader.foregroundJob(processGroupID: $0) }
            let startedAt = groupID.flatMap { ForegroundJobReader.processStartedAt(pid: $0) }
            // An inconclusive probe pauses recovery; it must not grant a fresh
            // attempt budget by removing and recreating an otherwise live target.
            let matches =
              job.map { AgentKindPatterns.classify(foregroundJob: $0) == entry.kind } == true
              && startedAt != nil
            result.append(
              Target(
                paneID: pane.id, generation: entry.recoveryGeneration,
                kind: entry.kind, sessionID: entry.sessionID,
                directory: URL(fileURLWithPath: worktree.path),
                isError: matches && entry.state == .error && entry.recoveryEligible,
                isBusy: !matches || entry.state == .working || entry.state == .blocked,
                processGroupID: groupID, processStartedAt: startedAt
              ))
          }
        }
      }
    }
    return result
  }
}
