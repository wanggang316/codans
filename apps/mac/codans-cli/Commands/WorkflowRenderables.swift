import CodansCore
import CodansIPC
import CodansKit
import Foundation

// `--json` shapes for `workflow.*`. Hierarchy ids ride the wire as
// `{raw: uuid}` objects and dates as reference-date seconds; every other
// verb prints ids as plain strings, so the run-shaped payloads are
// re-shaped here (ids → strings, dates → ISO-8601) instead of being passed
// through. The schema in Resources/schema/cli-output.schema.json describes
// these output structs, not the wire types.

enum WorkflowTextFormat {
  /// `2026-09-18T09:30:00Z`, the same shape `agent status` prints.
  static func date(_ date: Date) -> String {
    date.formatted(.iso8601)
  }

  static func date(_ date: Date?) -> String? {
    date.map(Self.date(_:))
  }

  static func shortRunID(_ id: UUID) -> String {
    String(id.uuidString.prefix(8)).lowercased()
  }
}

struct WorkflowBindingOutput: Encodable {
  let role: String
  let source: String
  let paneID: String?
  let handle: String?
  let profileID: String?
  let profileName: String?
  let agent: String?

  init(_ binding: IPC.WorkflowRoleBindingSummary) {
    role = binding.role
    source = binding.source
    paneID = binding.paneID?.description
    handle = binding.handle
    profileID = binding.profileID?.uuidString
    profileName = binding.profileName
    agent = binding.agent
  }

  /// `reviewer: launch → p4 (Claude Code, claude)`
  var line: String {
    var target = handle ?? paneID ?? "unbound"
    let profile = [profileName, agent].compactMap { $0 }
    if !profile.isEmpty { target += " (\(profile.joined(separator: ", ")))" }
    return "\(role): \(source) → \(target)"
  }
}

struct WorkflowActivationOutput: Encodable {
  let stepID: String
  let role: String
  let delivery: String
  let state: String
  let ordinal: Int
  let deadline: String?
  let completionCommands: [String]

  init(_ activation: IPC.WorkflowActivationSummary) {
    stepID = activation.stepID
    role = activation.role
    delivery = activation.delivery
    state = activation.state
    ordinal = activation.ordinal
    deadline = WorkflowTextFormat.date(activation.deadline)
    completionCommands = activation.completionCommands
  }
}

struct WorkflowRunOutput: Encodable {
  let runID: String
  let workflowID: String
  let workflowName: String
  let state: String
  let dependent: String?
  let attention: IPC.WorkflowAttentionSummary?
  let startedAt: String
  let finishedAt: String?
  let runDirectory: String
  let worktreeID: String?
  let currentStep: IPC.WorkflowStepSummary?
  let phase: String?
  let activation: WorkflowActivationOutput?
  let deliveries: [IPC.WorkflowDeliverySummary]
  let bindings: [WorkflowBindingOutput]
  let steps: [IPC.WorkflowStepSummary]

  init(_ run: IPC.WorkflowRunSummary) {
    runID = run.runID.uuidString
    workflowID = run.workflowID
    workflowName = run.workflowName
    state = run.state
    dependent = run.dependent
    attention = run.attention
    startedAt = WorkflowTextFormat.date(run.startedAt)
    finishedAt = WorkflowTextFormat.date(run.finishedAt)
    runDirectory = run.runDirectory
    worktreeID = run.worktreeID?.description
    currentStep = run.currentStep
    phase = run.phase
    activation = run.activation.map(WorkflowActivationOutput.init)
    deliveries = run.deliveries
    bindings = run.bindings.map(WorkflowBindingOutput.init)
    steps = run.steps
  }
}

// MARK: - list

struct WorkflowListRenderable: Encodable, CustomStringConvertible {
  let response: IPC.WorkflowListResponse

  func encode(to encoder: Encoder) throws {
    try response.encode(to: encoder)
  }

  var description: String {
    guard !response.workflows.isEmpty else { return "(no workflows)" }
    var lines: [String] = []
    for workflow in response.workflows {
      lines.append("\(workflow.id)  \(workflow.name)  \(workflow.scope.rawValue)  \(Self.status(of: workflow))")
      guard !workflow.isValid || workflow.diagnostics.contains(where: { !$0.isError }) else { continue }
      for diagnostic in workflow.diagnostics {
        let location = diagnostic.path.map { " (\($0))" } ?? ""
        lines.append("    \(diagnostic.severity.rawValue) \(diagnostic.code): \(diagnostic.message)\(location)")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func status(of workflow: IPC.WorkflowSummary) -> String {
    if !workflow.isValid { return "invalid" }
    if !workflow.isEnabled { return "disabled" }
    if workflow.requiresTrust, !workflow.isTrusted { return "valid (untrusted)" }
    return "valid"
  }
}

// MARK: - run

struct WorkflowRunRenderable: Encodable, CustomStringConvertible {
  let response: IPC.WorkflowRunResponse

  private enum Key: String, CodingKey {
    case runID, workflowID, workflowName, runDirectory, bindings, selfInitiated
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(response.runID.uuidString, forKey: .runID)
    try container.encode(response.workflowID, forKey: .workflowID)
    try container.encode(response.workflowName, forKey: .workflowName)
    try container.encode(response.runDirectory, forKey: .runDirectory)
    try container.encode(response.bindings.map(WorkflowBindingOutput.init), forKey: .bindings)
    try container.encodeIfPresent(response.selfInitiated, forKey: .selfInitiated)
  }

  var description: String {
    var lines = ["started \(response.workflowName) (run \(response.runID.uuidString))"]
    lines.append("  run directory: \(response.runDirectory)")
    for binding in response.bindings.map(WorkflowBindingOutput.init) {
      lines.append("  \(binding.line)")
    }
    if let task = response.selfInitiated {
      lines.append(contentsOf: Self.selfInitiatedBlock(task))
    }
    return lines.joined(separator: "\n")
  }

  /// The calling agent is the `current` role and the first step is its
  /// own: nothing was typed into its pane, so the task is spelled out here
  /// with the exact command that completes it.
  private static func selfInitiatedBlock(_ task: IPC.WorkflowSelfInitiatedTask) -> [String] {
    var lines = [
      "",
      "==== YOUR TASK (step \(task.stepID)) ====",
      "This step is yours: nothing was typed into your pane. Perform the task below yourself.",
      "",
      task.line,
    ]
    if let path = task.instructionPath {
      lines.append("")
      lines.append("Full instructions: \(path)")
    }
    lines.append("")
    lines.append("When you are done, run exactly:")
    lines.append("  \(task.completionCommand)")
    lines.append("==== END TASK ====")
    return lines
  }
}

// MARK: - status / resolve / cancel

struct WorkflowStatusRenderable: Encodable, CustomStringConvertible {
  let response: IPC.WorkflowStatusResponse

  private enum Key: String, CodingKey { case run, participant }

  private struct Participant: Encodable {
    let role: String
    let paneID: String
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(WorkflowRunOutput(response.run), forKey: .run)
    try container.encodeIfPresent(
      response.participant.map { Participant(role: $0.role, paneID: $0.paneID.description) },
      forKey: .participant)
  }

  var description: String {
    let run = response.run
    var lines = ["\(run.workflowName) · \(Self.stateLabel(run))"]
    lines.append("  run: \(run.runID.uuidString)")
    if let step = run.currentStep {
      let phase = run.phase.map { " [\($0)]" } ?? ""
      lines.append("  step: \(Self.stepLabel(step))\(phase)")
    }
    if let participant = response.participant {
      lines.append("  you: \(participant.role) in pane \(participant.paneID)")
    }
    if let attention = run.attention {
      lines.append(contentsOf: Self.attentionBlock(attention))
    }
    if let activation = run.activation {
      lines.append(contentsOf: Self.activationBlock(activation))
    }
    if !run.deliveries.isEmpty {
      lines.append("deliveries:")
      lines.append(contentsOf: run.deliveries.map(Self.deliveryLine))
    }
    return lines.joined(separator: "\n")
  }

  private static func stateLabel(_ run: IPC.WorkflowRunSummary) -> String {
    guard run.state == "skipped", let dependent = run.dependent else { return run.state }
    return "skipped (needed by \(dependent))"
  }

  static func stepLabel(_ step: IPC.WorkflowStepSummary) -> String {
    let name = step.name.map { " (\($0))" } ?? ""
    let iteration = step.iteration.map { " iteration \($0)" } ?? ""
    return "\(step.id)\(name)\(iteration)"
  }

  private static func attentionBlock(_ attention: IPC.WorkflowAttentionSummary) -> [String] {
    var lines = ["attention: \(attention.reason) (step \(attention.stepID))"]
    lines.append("  \(attention.message)")
    for issue in attention.issues {
      lines.append("  - \(issue)")
    }
    if !attention.actions.isEmpty {
      lines.append("  actions: \(attention.actions.joined(separator: ", "))")
    }
    return lines
  }

  private static func activationBlock(_ activation: IPC.WorkflowActivationSummary) -> [String] {
    let deadline = WorkflowTextFormat.date(activation.deadline).map { ", until \($0)" } ?? ""
    var lines = [
      "waiting for: \(activation.delivery) from \(activation.role)"
        + " (step \(activation.stepID), ordinal \(activation.ordinal), \(activation.state)\(deadline))"
    ]
    if !activation.completionCommands.isEmpty {
      lines.append("  finish with:")
      lines.append(contentsOf: activation.completionCommands.map { "    \($0)" })
    }
    return lines
  }

  private static func deliveryLine(_ delivery: IPC.WorkflowDeliverySummary) -> String {
    let verdict = delivery.verdict ?? "-"
    let provisional = delivery.isProvisional ? "  provisional" : ""
    return "  \(delivery.name)  #\(delivery.ordinal)  \(verdict)\(provisional)  \(delivery.path)"
  }
}

// MARK: - deliver

struct WorkflowDeliverRenderable: Encodable, CustomStringConvertible {
  let response: IPC.WorkflowDeliverResponse

  func encode(to encoder: Encoder) throws {
    try response.encode(to: encoder)
  }

  var description: String {
    let target = "\(response.delivery) (ordinal \(response.ordinal)) → \(response.path)"
    guard response.state == "provisional" else {
      return "Delivered \(target)"
    }
    var lines = ["Provisional delivery \(target)"]
    lines.append(contentsOf: response.issues.map { "  - \($0)" })
    lines.append("The run now waits for the user to accept, ask again, or skip this step.")
    return lines.joined(separator: "\n")
  }
}

// MARK: - runs

struct WorkflowRunListRenderable: Encodable, CustomStringConvertible {
  let response: IPC.WorkflowRunListResponse

  private enum Key: String, CodingKey { case runs }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(response.runs.map(WorkflowRunOutput.init), forKey: .runs)
  }

  var description: String {
    guard !response.runs.isEmpty else { return "(no runs)" }
    return response.runs.map { run in
      let started = WorkflowTextFormat.date(run.startedAt)
      let finished = WorkflowTextFormat.date(run.finishedAt) ?? "-"
      return "\(WorkflowTextFormat.shortRunID(run.runID))  \(run.workflowID)  \(run.state)  \(started)  \(finished)"
    }.joined(separator: "\n")
  }
}
