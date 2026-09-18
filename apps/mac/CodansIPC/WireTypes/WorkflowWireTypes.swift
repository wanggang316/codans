import CodansCore
import Foundation

// `workflow.*` wire contract. Plain value types: every enum-like field the
// server derives from a richer domain type (role source, run state, phase,
// attention reason, …) rides as a `String` so the contract does not have to
// move in lock step with the run machine's own types. Dates are `Date` and
// take the default `JSONEncoder` representation both sides already use for
// every other payload; the CLI renders them as ISO-8601 for humans.

extension IPC {
  /// Where a workflow definition was found. Shadowing order is
  /// repo > user > bundle.
  public enum WorkflowScope: String, Codable, Equatable, Sendable, CaseIterable {
    case bundle
    case user
    case repo
  }

  /// One role of a listed definition, as much as a caller needs to build
  /// a `--role` argument.
  public struct WorkflowRoleSummary: Codable, Equatable, Sendable {
    public let name: String
    /// `current` | `launch` | `pick`.
    public let source: String
    /// `launch` only: agent-kind allow-list, `nil` when any qualifies.
    public let agents: [String]?
    /// `launch` only: the definition's preferred profile display name.
    public let profile: String?

    public init(name: String, source: String, agents: [String]? = nil, profile: String? = nil) {
      self.name = name
      self.source = source
      self.agents = agents
      self.profile = profile
    }
  }

  public struct WorkflowInputSummary: Codable, Equatable, Sendable {
    public let name: String
    /// `string` | `number` | `boolean` | `choice`.
    public let kind: String
    public let required: Bool
    public let defaultValue: WorkflowValue?
    public let description: String?
    /// `choice` only.
    public let options: [String]

    public init(
      name: String,
      kind: String,
      required: Bool,
      defaultValue: WorkflowValue? = nil,
      description: String? = nil,
      options: [String] = []
    ) {
      self.name = name
      self.kind = kind
      self.required = required
      self.defaultValue = defaultValue
      self.description = description
      self.options = options
    }
  }

  /// One row of `workflow.list`: a definition file as discovery sees it,
  /// including one that failed to parse (`isValid == false` with the
  /// diagnostics that say why).
  public struct WorkflowSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let scope: WorkflowScope
    public let path: String
    public let isEnabled: Bool
    public let isValid: Bool
    public let diagnostics: [WorkflowDiagnostic]
    public let roles: [WorkflowRoleSummary]
    public let inputs: [WorkflowInputSummary]
    /// Repository-scoped and runs shell commands, so it needs the user's
    /// trust before it can start.
    public let requiresTrust: Bool
    public let isTrusted: Bool

    public init(
      id: String,
      name: String,
      description: String? = nil,
      scope: WorkflowScope,
      path: String,
      isEnabled: Bool,
      isValid: Bool,
      diagnostics: [WorkflowDiagnostic] = [],
      roles: [WorkflowRoleSummary] = [],
      inputs: [WorkflowInputSummary] = [],
      requiresTrust: Bool = false,
      isTrusted: Bool = false
    ) {
      self.id = id
      self.name = name
      self.description = description
      self.scope = scope
      self.path = path
      self.isEnabled = isEnabled
      self.isValid = isValid
      self.diagnostics = diagnostics
      self.roles = roles
      self.inputs = inputs
      self.requiresTrust = requiresTrust
      self.isTrusted = isTrusted
    }
  }

  /// Params for `workflow.list`. Both nil means "attribute the caller from
  /// the connection's peer PID; outside a pane, list every scope".
  public struct WorkflowListRequest: Codable, Equatable, Sendable {
    public let worktreeID: WorktreeID?
    public let paneID: PaneID?

    public init(worktreeID: WorktreeID? = nil, paneID: PaneID? = nil) {
      self.worktreeID = worktreeID
      self.paneID = paneID
    }
  }

  public struct WorkflowListResponse: Codable, Equatable, Sendable {
    public let workflows: [WorkflowSummary]

    public init(workflows: [WorkflowSummary]) {
      self.workflows = workflows
    }
  }

  /// Params for `workflow.run`. `sourcePaneID` nil with `worktreeID` nil
  /// asks the server to attribute the caller's pane from the peer PID.
  public struct WorkflowRunRequest: Codable, Equatable, Sendable {
    /// Definition id, or its unique display name.
    public let workflow: String
    public let sourcePaneID: PaneID?
    public let worktreeID: WorktreeID?
    /// Role name → binding (`auto`, a profile name or id, or a pane
    /// reference for `pick` roles).
    public let roles: [String: String]
    /// Input name → raw text; the server types it against the definition.
    public let inputs: [String: String]
    public let skip: [String]
    /// `cli` | `gui`.
    public let origin: String

    public init(
      workflow: String,
      sourcePaneID: PaneID? = nil,
      worktreeID: WorktreeID? = nil,
      roles: [String: String] = [:],
      inputs: [String: String] = [:],
      skip: [String] = [],
      origin: String = "cli"
    ) {
      self.workflow = workflow
      self.sourcePaneID = sourcePaneID
      self.worktreeID = worktreeID
      self.roles = roles
      self.inputs = inputs
      self.skip = skip
      self.origin = origin
    }
  }

  /// A role as frozen into a run: the pane it is (or will be) bound to and,
  /// for `launch` roles, the profile that was resolved at admission.
  public struct WorkflowRoleBindingSummary: Codable, Equatable, Sendable {
    public let role: String
    /// `current` | `launch` | `pick`.
    public let source: String
    public let paneID: PaneID?
    /// `p<n>` handle for display, when the pane is known.
    public let handle: String?
    public let profileID: UUID?
    public let profileName: String?
    public let agent: String?

    public init(
      role: String,
      source: String,
      paneID: PaneID? = nil,
      handle: String? = nil,
      profileID: UUID? = nil,
      profileName: String? = nil,
      agent: String? = nil
    ) {
      self.role = role
      self.source = source
      self.paneID = paneID
      self.handle = handle
      self.profileID = profileID
      self.profileName = profileName
      self.agent = agent
    }
  }

  /// Returned when `run` was called from the pane that becomes the
  /// `current` role and the first step messages that role: the calling
  /// agent already holds the task, so the engine types nothing into its
  /// pane and hands it the rendered line instead.
  public struct WorkflowSelfInitiatedTask: Codable, Equatable, Sendable {
    public let stepID: String
    /// The single line the engine would have typed (`text`, or the
    /// pointer to `instructionPath`).
    public let line: String
    public let instructionPath: String?
    /// The exact command that completes the step, token included.
    public let completionCommand: String

    public init(stepID: String, line: String, instructionPath: String? = nil, completionCommand: String) {
      self.stepID = stepID
      self.line = line
      self.instructionPath = instructionPath
      self.completionCommand = completionCommand
    }
  }

  public struct WorkflowRunResponse: Codable, Equatable, Sendable {
    public let runID: UUID
    public let workflowID: String
    public let workflowName: String
    public let runDirectory: String
    public let bindings: [WorkflowRoleBindingSummary]
    public let selfInitiated: WorkflowSelfInitiatedTask?

    public init(
      runID: UUID,
      workflowID: String,
      workflowName: String,
      runDirectory: String,
      bindings: [WorkflowRoleBindingSummary],
      selfInitiated: WorkflowSelfInitiatedTask? = nil
    ) {
      self.runID = runID
      self.workflowID = workflowID
      self.workflowName = workflowName
      self.runDirectory = runDirectory
      self.bindings = bindings
      self.selfInitiated = selfInitiated
    }
  }

  /// Why a run is in `needs_attention` and what the user may do about it.
  /// `actions` is the server's table, rendered as-is by every client.
  public struct WorkflowAttentionSummary: Codable, Equatable, Sendable {
    public let reason: String
    public let message: String
    public let stepID: String
    public let role: String?
    public let ordinal: Int?
    public let actions: [String]
    /// Provisional delivery: what the validator objected to.
    public let issues: [String]

    public init(
      reason: String,
      message: String,
      stepID: String,
      role: String? = nil,
      ordinal: Int? = nil,
      actions: [String],
      issues: [String] = []
    ) {
      self.reason = reason
      self.message = message
      self.stepID = stepID
      self.role = role
      self.ordinal = ordinal
      self.actions = actions
      self.issues = issues
    }
  }

  /// The delivery the run is currently waiting for. Never carries the
  /// token itself; `completionCommands` are the rendered lines an agent
  /// runs to finish the step.
  public struct WorkflowActivationSummary: Codable, Equatable, Sendable {
    public let stepID: String
    public let role: String
    public let delivery: String
    /// `waiting` | `persisting` | `provisional` | `delivered` | `skipped` | `revoked`.
    public let state: String
    public let ordinal: Int
    public let deadline: Date?
    public let completionCommands: [String]

    public init(
      stepID: String,
      role: String,
      delivery: String,
      state: String,
      ordinal: Int,
      deadline: Date? = nil,
      completionCommands: [String]
    ) {
      self.stepID = stepID
      self.role = role
      self.delivery = delivery
      self.state = state
      self.ordinal = ordinal
      self.deadline = deadline
      self.completionCommands = completionCommands
    }
  }

  public struct WorkflowDeliverySummary: Codable, Equatable, Sendable {
    public let name: String
    public let ordinal: Int
    /// `deliveries/<name>.<ordinal>.md`, absolute.
    public let path: String
    /// `deliveries/<name>.md`, absolute — the latest-wins view.
    public let latestPath: String
    public let verdict: String?
    public let isProvisional: Bool

    public init(
      name: String,
      ordinal: Int,
      path: String,
      latestPath: String,
      verdict: String? = nil,
      isProvisional: Bool = false
    ) {
      self.name = name
      self.ordinal = ordinal
      self.path = path
      self.latestPath = latestPath
      self.verdict = verdict
      self.isProvisional = isProvisional
    }
  }

  public struct WorkflowStepSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    /// `success` | `failure` | `skipped`; nil while pending or active.
    public let outcome: String?
    /// Loop iteration the step ran in; nil outside a loop.
    public let iteration: Int?

    public init(id: String, name: String? = nil, outcome: String? = nil, iteration: Int? = nil) {
      self.id = id
      self.name = name
      self.outcome = outcome
      self.iteration = iteration
    }
  }

  /// Everything `workflow.status` / `workflow.listRuns` say about one run.
  /// `state` is the machine's status (`running`, `needs_attention`,
  /// `completed`, `cancelled`, `skipped`, `iteration_limit_reached`,
  /// `failed`, `interrupted`); `dependent` names the step a `skipped` run
  /// could not satisfy.
  public struct WorkflowRunSummary: Codable, Equatable, Sendable {
    public let runID: UUID
    public let workflowID: String
    public let workflowName: String
    public let state: String
    public let dependent: String?
    public let attention: WorkflowAttentionSummary?
    public let startedAt: Date
    public let finishedAt: Date?
    public let runDirectory: String
    public let worktreeID: WorktreeID?
    public let currentStep: WorkflowStepSummary?
    public let phase: String?
    public let activation: WorkflowActivationSummary?
    public let deliveries: [WorkflowDeliverySummary]
    public let bindings: [WorkflowRoleBindingSummary]
    public let steps: [WorkflowStepSummary]

    public init(
      runID: UUID,
      workflowID: String,
      workflowName: String,
      state: String,
      dependent: String? = nil,
      attention: WorkflowAttentionSummary? = nil,
      startedAt: Date,
      finishedAt: Date? = nil,
      runDirectory: String,
      worktreeID: WorktreeID? = nil,
      currentStep: WorkflowStepSummary? = nil,
      phase: String? = nil,
      activation: WorkflowActivationSummary? = nil,
      deliveries: [WorkflowDeliverySummary] = [],
      bindings: [WorkflowRoleBindingSummary] = [],
      steps: [WorkflowStepSummary] = []
    ) {
      self.runID = runID
      self.workflowID = workflowID
      self.workflowName = workflowName
      self.state = state
      self.dependent = dependent
      self.attention = attention
      self.startedAt = startedAt
      self.finishedAt = finishedAt
      self.runDirectory = runDirectory
      self.worktreeID = worktreeID
      self.currentStep = currentStep
      self.phase = phase
      self.activation = activation
      self.deliveries = deliveries
      self.bindings = bindings
      self.steps = steps
    }
  }

  /// Params for `workflow.status`. Without `runID` the server answers
  /// "which run am I in": it looks up `callerPaneID` (or, when that is nil
  /// too, the pane attributed from the peer PID) in the activation
  /// registry and returns that run plus the caller's `participant` row.
  public struct WorkflowStatusRequest: Codable, Equatable, Sendable {
    public let runID: UUID?
    public let callerPaneID: PaneID?

    public init(runID: UUID? = nil, callerPaneID: PaneID? = nil) {
      self.runID = runID
      self.callerPaneID = callerPaneID
    }
  }

  public struct WorkflowParticipantSummary: Codable, Equatable, Sendable {
    public let role: String
    public let paneID: PaneID

    public init(role: String, paneID: PaneID) {
      self.role = role
      self.paneID = paneID
    }
  }

  public struct WorkflowStatusResponse: Codable, Equatable, Sendable {
    public let run: WorkflowRunSummary
    public let participant: WorkflowParticipantSummary?

    public init(run: WorkflowRunSummary, participant: WorkflowParticipantSummary? = nil) {
      self.run = run
      self.participant = participant
    }
  }

  /// Params for `workflow.deliver`. The activation is found through the
  /// caller's pane and confirmed by `token`; `runID` + `stepID` are the
  /// explicit route for a caller outside any pane (recorded as a manual
  /// delivery). `force` accepts a body the validator would otherwise
  /// reject under `strict`.
  public struct WorkflowDeliverRequest: Codable, Equatable, Sendable {
    public let callerPaneID: PaneID?
    public let token: String?
    public let runID: UUID?
    public let stepID: String?
    public let body: String
    public let verdict: String?
    public let force: Bool

    public init(
      callerPaneID: PaneID? = nil,
      token: String? = nil,
      runID: UUID? = nil,
      stepID: String? = nil,
      body: String,
      verdict: String? = nil,
      force: Bool = false
    ) {
      self.callerPaneID = callerPaneID
      self.token = token
      self.runID = runID
      self.stepID = stepID
      self.body = body
      self.verdict = verdict
      self.force = force
    }
  }

  public struct WorkflowDeliverResponse: Codable, Equatable, Sendable {
    public let runID: UUID
    public let stepID: String
    public let delivery: String
    public let ordinal: Int
    /// `delivered` | `provisional`.
    public let state: String
    public let path: String
    /// Provisional only: what is missing, for the agent and the user.
    public let issues: [String]

    public init(
      runID: UUID,
      stepID: String,
      delivery: String,
      ordinal: Int,
      state: String,
      path: String,
      issues: [String] = []
    ) {
      self.runID = runID
      self.stepID = stepID
      self.delivery = delivery
      self.ordinal = ordinal
      self.state = state
      self.path = path
      self.issues = issues
    }
  }

  /// Params for `workflow.resolve`. `action` is one of the run's current
  /// `attention.actions`; `verdict` accompanies `accept-with-verdict`.
  public struct WorkflowResolveRequest: Codable, Equatable, Sendable {
    public let runID: UUID
    public let action: String
    public let verdict: String?

    public init(runID: UUID, action: String, verdict: String? = nil) {
      self.runID = runID
      self.action = action
      self.verdict = verdict
    }
  }

  public struct WorkflowCancelRequest: Codable, Equatable, Sendable {
    public let runID: UUID

    public init(runID: UUID) {
      self.runID = runID
    }
  }

  /// Params for `workflow.listRuns`; scoping follows `WorkflowListRequest`.
  public struct WorkflowListRunsRequest: Codable, Equatable, Sendable {
    public let worktreeID: WorktreeID?
    public let paneID: PaneID?
    public let limit: Int?

    public init(worktreeID: WorktreeID? = nil, paneID: PaneID? = nil, limit: Int? = nil) {
      self.worktreeID = worktreeID
      self.paneID = paneID
      self.limit = limit
    }
  }

  public struct WorkflowRunListResponse: Codable, Equatable, Sendable {
    public let runs: [WorkflowRunSummary]

    public init(runs: [WorkflowRunSummary]) {
      self.runs = runs
    }
  }
}
