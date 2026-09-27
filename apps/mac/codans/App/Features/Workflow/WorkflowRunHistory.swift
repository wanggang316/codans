import CodansCore
import Foundation

/// One row of the Workflow Runs panel: a live run from the engine or a
/// past one read back from a worktree's `.codans/workflow-runs` index.
nonisolated struct WorkflowRunSummary: Identifiable, Equatable, Sendable {
  let id: UUID
  let name: String
  let status: String
  let isTerminal: Bool
  let needsAttention: Bool
  let startedAt: Date
  let finishedAt: Date?
  let worktreeName: String
  let worktreePath: String
  let runDirectory: URL
}

/// Past runs from disk, across every local worktree the hierarchy knows —
/// what survives a relaunch, unlike the engine's in-memory finished list.
nonisolated enum WorkflowRunHistory {
  /// Newest first, capped per worktree so a long-lived repository does not
  /// flood the list.
  static func load(worktrees: [(name: String, path: String)], perWorktree: Int = 50) -> [WorkflowRunSummary] {
    var summaries: [WorkflowRunSummary] = []
    for worktree in worktrees {
      let root = URL(fileURLWithPath: worktree.path, isDirectory: true)
      guard let index = try? WorkflowRunIndex.load(worktreeRoot: root) else { continue }
      let recent = index.runs.sorted { $0.startedAt > $1.startedAt }.prefix(perWorktree)
      for entry in recent {
        summaries.append(
          WorkflowRunSummary(
            id: entry.id,
            name: entry.workflowName,
            status: entry.status,
            isTerminal: entry.isTerminal,
            needsAttention: entry.status == "needs_attention",
            startedAt: entry.startedAt,
            finishedAt: entry.finishedAt,
            worktreeName: worktree.name,
            worktreePath: worktree.path,
            runDirectory: WorkflowRunLayout.runDirectory(worktreeRoot: root, runID: entry.id)))
      }
    }
    return summaries.sorted { $0.startedAt > $1.startedAt }
  }

  /// Step rows for a past run: the definition it froze at start, with each
  /// step's recorded outcome.
  static func stepRows(runDirectory: URL) -> [WorkflowRunDisplay.StepRow] {
    let store = WorkflowRunStore(runDirectory: runDirectory)
    guard
      let record = try? store.readRecord(),
      let yaml = try? String(
        contentsOf: WorkflowRunLayout.definitionURL(runDirectory: runDirectory), encoding: .utf8),
      let definition = WorkflowDocumentParser.parse(yaml: yaml, id: record.workflowID).definition
    else { return [] }
    return definition.flattenedSteps.map { step in
      let status: WorkflowRunDisplay.StepStatus
      switch record.steps[step.id]?.outcome {
      case .success: status = .done
      case .failure: status = .failed
      case .skipped: status = .skipped
      case nil: status = .pending
      }
      return WorkflowRunDisplay.StepRow(id: step.id, name: step.displayName, status: status)
    }
  }

  /// Delivery files, oldest first (`<name>.<n>.md`), without the
  /// `<name>.md` "latest" copies that duplicate the last of each.
  static func deliveries(runDirectory: URL) -> [URL] {
    let directory = WorkflowRunLayout.deliveriesDirectory(runDirectory: runDirectory)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
    return
      names
      .filter { $0.split(separator: ".").count >= 3 }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      .map { directory.appendingPathComponent($0) }
  }
}
