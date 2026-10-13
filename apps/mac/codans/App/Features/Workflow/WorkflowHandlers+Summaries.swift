import CodansCore
import CodansIPC
import Foundation

/// Wire summaries for runs, live and on disk. The activation's completion
/// command carries the token, so it is spelled out only for the pane that
/// is meant to run it.
extension WorkflowHandlers {
  func summary(_ session: WorkflowRunSession, callerPaneID: PaneID?) -> IPC.WorkflowRunSummary {
    let run = session.run
    return IPC.WorkflowRunSummary(
      runID: run.id,
      workflowID: run.definition.id,
      workflowName: run.definition.name,
      state: run.status.stateName,
      dependent: Self.dependent(run.status),
      attention: run.status.attention.map(Self.attentionSummary),
      startedAt: run.configuration.startedAt,
      finishedAt: run.finishedAt,
      runDirectory: run.configuration.runDirectory,
      worktreeID: run.configuration.source.worktreeID,
      currentStep: run.currentStep.map { Self.stepSummary($0, record: run.steps[$0.id]) },
      phase: run.phase.name,
      activation: run.currentActivation.map { activationSummary($0, run: run, callerPaneID: callerPaneID) },
      deliveries: run.deliveries.values.sorted { $0.ordinal < $1.ordinal }.map(Self.deliverySummary),
      bindings: bindingSummaries(run.bindings, definition: run.definition),
      steps: run.definition.flattenedSteps.map { Self.stepSummary($0, record: run.steps[$0.id]) }
    )
  }

  /// A record read back from `run.json`. One still `running` on disk has
  /// no engine behind it any more, so it is reported as `interrupted`.
  func summary(_ record: WorkflowRunRecord) -> IPC.WorkflowRunSummary {
    let interrupted = !record.status.isTerminal
    let steps = record.steps.values.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    return IPC.WorkflowRunSummary(
      runID: record.id,
      workflowID: record.workflowID,
      workflowName: record.workflowName,
      state: interrupted ? WorkflowRunStatus.interrupted.stateName : record.status.stateName,
      dependent: Self.dependent(record.status),
      attention: nil,
      startedAt: record.startedAt,
      finishedAt: record.finishedAt,
      runDirectory: record.runDirectory,
      worktreeID: record.source.worktreeID,
      currentStep: record.currentStepID.map { IPC.WorkflowStepSummary(id: $0) },
      phase: interrupted ? nil : record.phase,
      deliveries: record.deliveries.values.sorted { $0.ordinal < $1.ordinal }.map(Self.deliverySummary),
      bindings: bindingSummaries(record.bindings, definition: nil),
      steps: steps.map {
        IPC.WorkflowStepSummary(id: $0.stepID, outcome: $0.outcome?.rawValue, iteration: $0.iteration)
      }
    )
  }

  func summary(_ entry: WorkflowRunIndex.Entry, worktreeID: WorktreeID, worktreeRoot: URL) -> IPC.WorkflowRunSummary {
    let interrupted = !entry.isTerminal
    return IPC.WorkflowRunSummary(
      runID: entry.id,
      workflowID: entry.workflowID,
      workflowName: entry.workflowName,
      state: interrupted ? WorkflowRunStatus.interrupted.stateName : entry.status,
      startedAt: entry.startedAt,
      finishedAt: entry.finishedAt,
      runDirectory: WorkflowRunLayout.runDirectory(worktreeRoot: worktreeRoot, runID: entry.id)
        .path(percentEncoded: false),
      worktreeID: worktreeID
    )
  }

  // MARK: - Pieces

  static func dependent(_ status: WorkflowRunStatus) -> String? {
    if case .skipped(_, let dependent) = status { return dependent }
    return nil
  }

  static func attentionSummary(_ attention: WorkflowAttention) -> IPC.WorkflowAttentionSummary {
    IPC.WorkflowAttentionSummary(
      reason: attention.reason.rawValue,
      message: attention.message,
      stepID: attention.stepID,
      role: attention.role,
      ordinal: attention.ordinal,
      actions: attention.actions.map(\.rawValue),
      issues: attention.issues)
  }

  static func stepSummary(_ step: WorkflowStep, record: WorkflowStepRecord?) -> IPC.WorkflowStepSummary {
    IPC.WorkflowStepSummary(
      id: step.id, name: step.name, outcome: record?.outcome?.rawValue, iteration: record?.iteration)
  }

  static func deliverySummary(_ record: WorkflowDeliveryRecord) -> IPC.WorkflowDeliverySummary {
    IPC.WorkflowDeliverySummary(
      name: record.name,
      ordinal: record.ordinal,
      path: record.path,
      latestPath: record.latestPath,
      verdict: record.verdict,
      isProvisional: record.isProvisional)
  }

  func activationSummary(
    _ activation: WorkflowActivation, run: WorkflowRunState, callerPaneID: PaneID?
  ) -> IPC.WorkflowActivationSummary {
    var commands: [String] = []
    if let callerPaneID, callerPaneID == activation.paneID {
      commands = [
        WorkflowCompletionCommand.render(
          cli: run.configuration.cliCommand, token: activation.token, verdicts: activation.expectation.verdicts)
      ]
    }
    return IPC.WorkflowActivationSummary(
      stepID: activation.stepID,
      role: activation.role,
      delivery: activation.delivery,
      state: activation.state.rawValue,
      ordinal: activation.ordinal,
      deadline: activation.deadline,
      completionCommands: commands)
  }

  func bindingSummaries(
    _ bindings: [String: WorkflowRoleBinding], definition: WorkflowDefinition?
  ) -> [IPC.WorkflowRoleBindingSummary] {
    let order = definition?.roles.map(\.name) ?? bindings.keys.sorted()
    let handles = paneHandles()
    return order.compactMap { role -> IPC.WorkflowRoleBindingSummary? in
      guard let binding = bindings[role] else { return nil }
      let handle = binding.paneID.flatMap { handles[$0] }.map { "p\($0)" }
      switch binding {
      case .current(let paneID), .pick(let paneID):
        return IPC.WorkflowRoleBindingSummary(
          role: role, source: binding.source.rawValue, paneID: paneID, handle: handle)
      case .launch(let profileID, let profileName, let agent, let paneID):
        return IPC.WorkflowRoleBindingSummary(
          role: role, source: binding.source.rawValue, paneID: paneID, handle: handle,
          profileID: profileID, profileName: profileName, agent: agent.rawValue)
      }
    }
  }

  func selfInitiatedSummary(_ task: WorkflowSelfInitiatedTask) -> IPC.WorkflowSelfInitiatedTask? {
    guard let command = task.completionCommand else {
      return IPC.WorkflowSelfInitiatedTask(
        stepID: task.stepID, line: task.line, instructionPath: task.instructionPath, completionCommand: "")
    }
    return IPC.WorkflowSelfInitiatedTask(
      stepID: task.stepID, line: task.line, instructionPath: task.instructionPath, completionCommand: command)
  }

  func workflowSummary(_ entry: WorkflowCatalogEntry, settings: WorkflowSettings) -> IPC.WorkflowSummary {
    let definition = entry.definition
    return IPC.WorkflowSummary(
      id: entry.id,
      name: entry.name,
      description: definition?.description,
      scope: IPC.WorkflowScope(rawValue: entry.scope.rawValue) ?? .user,
      path: entry.path,
      isEnabled: !settings.isDisabled(entry.id),
      isValid: entry.isValid,
      diagnostics: entry.diagnostics,
      roles: (definition?.roles ?? []).map {
        IPC.WorkflowRoleSummary(
          name: $0.name, source: $0.source.rawValue, agents: $0.agents?.map(\.rawValue), profile: $0.profile)
      },
      inputs: (definition?.inputs ?? []).map {
        IPC.WorkflowInputSummary(
          name: $0.name, kind: $0.kind.rawValue, required: $0.isRequired, defaultValue: $0.defaultValue,
          description: $0.description, options: $0.options)
      },
      requiresTrust: entry.requiresTrust,
      isTrusted: entry.requiresTrust && settings.isTrusted(path: entry.path, sha256: entry.sha256)
    )
  }
}
