import Foundation

// MARK: - Configuration

/// The worktree a run belongs to, frozen at admission. Roles never cross
/// worktrees, so every path a step renders is relative to this one.
public nonisolated struct WorkflowRunSource: Equatable, Sendable, Codable {
  public var projectID: ProjectID
  public var worktreeID: WorktreeID
  public var worktreePath: String
  public var worktreeName: String
  public var branch: String?

  public init(
    projectID: ProjectID,
    worktreeID: WorktreeID,
    worktreePath: String,
    worktreeName: String,
    branch: String? = nil
  ) {
    self.projectID = projectID
    self.worktreeID = worktreeID
    self.worktreePath = worktreePath
    self.worktreeName = worktreeName
    self.branch = branch
  }

  enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case worktreeID = "worktree_id"
    case worktreePath = "worktree_path"
    case worktreeName = "worktree_name"
    case branch
  }
}

/// How a role resolved on this machine. A `launch` binding carries the
/// frozen profile and gains its pane only once the launch succeeded.
public nonisolated enum WorkflowRoleBinding: Equatable, Sendable, Codable {
  case current(paneID: PaneID)
  case pick(paneID: PaneID)
  case launch(profileID: UUID, profileName: String, agent: AgentKind, paneID: PaneID?)

  public var paneID: PaneID? {
    switch self {
    case .current(let paneID), .pick(let paneID): return paneID
    case .launch(_, _, _, let paneID): return paneID
    }
  }

  public var isLaunch: Bool {
    if case .launch = self { return true }
    return false
  }

  /// The `source` keyword of the role this binding satisfies.
  public var source: WorkflowRole.Source {
    switch self {
    case .current: return .current
    case .pick: return .pick
    case .launch: return .launch
    }
  }

  enum CodingKeys: String, CodingKey {
    case source
    case paneID = "pane_id"
    case profileID = "profile_id"
    case profileName = "profile_name"
    case agent
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let source = try container.decode(String.self, forKey: .source)
    switch source {
    case "current":
      self = .current(paneID: try container.decode(PaneID.self, forKey: .paneID))
    case "pick":
      self = .pick(paneID: try container.decode(PaneID.self, forKey: .paneID))
    case "launch":
      self = .launch(
        profileID: try container.decode(UUID.self, forKey: .profileID),
        profileName: try container.decode(String.self, forKey: .profileName),
        agent: try container.decode(AgentKind.self, forKey: .agent),
        paneID: try container.decodeIfPresent(PaneID.self, forKey: .paneID)
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .source, in: container, debugDescription: "unknown role binding source \(source)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(source.rawValue, forKey: .source)
    switch self {
    case .current(let paneID), .pick(let paneID):
      try container.encode(paneID, forKey: .paneID)
    case .launch(let profileID, let profileName, let agent, let paneID):
      try container.encode(profileID, forKey: .profileID)
      try container.encode(profileName, forKey: .profileName)
      try container.encode(agent, forKey: .agent)
      try container.encodeIfPresent(paneID, forKey: .paneID)
    }
  }
}

/// Everything admission decided before the machine starts: the frozen
/// definition, resolved bindings, typed inputs, and where the run lives.
public nonisolated struct WorkflowRunConfiguration: Equatable, Sendable {
  public static let defaultIdleGraceSeconds = 180

  public var id: UUID
  public var definition: WorkflowDefinition
  public var source: WorkflowRunSource
  public var bindings: [String: WorkflowRoleBinding]
  /// Already typed and defaulted by admission.
  public var inputs: [String: WorkflowValue]
  public var skippedSteps: Set<String>
  /// Absolute path of `<worktree>/.codans/workflow-runs/<id>`.
  public var runDirectory: String
  /// How this build spells its CLI (`codans` / `codans-dev`), for the
  /// completion command and `codans.cli`.
  public var cliCommand: String
  /// The pane `codans workflow run` was invoked from, when any.
  public var initiatorPaneID: PaneID?
  public var startedAt: Date
  public var idleGraceSeconds: Int

  public init(
    id: UUID,
    definition: WorkflowDefinition,
    source: WorkflowRunSource,
    bindings: [String: WorkflowRoleBinding],
    inputs: [String: WorkflowValue] = [:],
    skippedSteps: Set<String> = [],
    runDirectory: String,
    cliCommand: String,
    initiatorPaneID: PaneID? = nil,
    startedAt: Date,
    idleGraceSeconds: Int = WorkflowRunConfiguration.defaultIdleGraceSeconds
  ) {
    self.id = id
    self.definition = definition
    self.source = source
    self.bindings = bindings
    self.inputs = inputs
    self.skippedSteps = skippedSteps
    self.runDirectory = runDirectory
    self.cliCommand = cliCommand
    self.initiatorPaneID = initiatorPaneID
    self.startedAt = startedAt
    self.idleGraceSeconds = idleGraceSeconds
  }
}

// MARK: - Records

public nonisolated enum WorkflowStepOutcome: String, Equatable, Sendable, Codable {
  case success
  case failure
  case skipped
}

public nonisolated struct WorkflowStepRecord: Equatable, Sendable, Codable {
  public var stepID: String
  public var outcome: WorkflowStepOutcome?
  public var startedAt: Date?
  public var finishedAt: Date?
  /// Loop iteration the step ran in, `nil` outside loops.
  public var iteration: Int?
  /// The invocation ordinal minted on entry, for steps that touch the
  /// outside world.
  public var ordinal: Int?

  public init(
    stepID: String,
    outcome: WorkflowStepOutcome? = nil,
    startedAt: Date? = nil,
    finishedAt: Date? = nil,
    iteration: Int? = nil,
    ordinal: Int? = nil
  ) {
    self.stepID = stepID
    self.outcome = outcome
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.iteration = iteration
    self.ordinal = ordinal
  }

  enum CodingKeys: String, CodingKey {
    case stepID = "step_id"
    case outcome
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case iteration
    case ordinal
  }
}

public nonisolated struct WorkflowDeliveryRecord: Equatable, Sendable, Codable {
  public var name: String
  public var ordinal: Int
  /// Absolute path of `deliveries/<name>.<ordinal>.md`.
  public var path: String
  /// Absolute path of `deliveries/<name>.md`.
  public var latestPath: String
  public var verdict: String?
  public var isProvisional: Bool
  public var deliveredAt: Date

  public init(
    name: String,
    ordinal: Int,
    path: String,
    latestPath: String,
    verdict: String? = nil,
    isProvisional: Bool = false,
    deliveredAt: Date
  ) {
    self.name = name
    self.ordinal = ordinal
    self.path = path
    self.latestPath = latestPath
    self.verdict = verdict
    self.isProvisional = isProvisional
    self.deliveredAt = deliveredAt
  }

  enum CodingKeys: String, CodingKey {
    case name
    case ordinal
    case path
    case latestPath = "latest_path"
    case verdict
    case isProvisional = "is_provisional"
    case deliveredAt = "delivered_at"
  }
}

// MARK: - Activations

public nonisolated enum WorkflowActivationState: String, Equatable, Sendable, Codable {
  case waiting
  case persisting
  case provisional
  case delivered
  case skipped
  case revoked
}

/// One `expect` in flight: the token the agent must present, and where
/// the delivery stands. The token lives only here — never in the record.
public nonisolated struct WorkflowActivation: Equatable, Sendable {
  public var ordinal: Int
  public var stepID: String
  public var role: String
  /// `nil` for a `launch` role until the pane exists.
  public var paneID: PaneID?
  public var delivery: String
  public var expectation: WorkflowExpectation
  public var token: String
  public var state: WorkflowActivationState
  /// Messages from the last validation, kept for the attention actions.
  public var issues: [String]
  /// Hard deadline from `expect.timeout-minutes`, set when the watchdog
  /// is armed.
  public var deadline: Date?
  public var nudged: Bool
  public var iteration: Int?
  /// The verdict presented with the delivery being persisted.
  public var verdict: String?
  /// A line waiting for the role to go idle (an "ask again" reminder).
  public var pendingLine: String?

  public init(
    ordinal: Int,
    stepID: String,
    role: String,
    paneID: PaneID?,
    delivery: String,
    expectation: WorkflowExpectation,
    token: String,
    state: WorkflowActivationState = .waiting,
    issues: [String] = [],
    deadline: Date? = nil,
    nudged: Bool = false,
    iteration: Int? = nil,
    verdict: String? = nil,
    pendingLine: String? = nil
  ) {
    self.ordinal = ordinal
    self.stepID = stepID
    self.role = role
    self.paneID = paneID
    self.delivery = delivery
    self.expectation = expectation
    self.token = token
    self.state = state
    self.issues = issues
    self.deadline = deadline
    self.nudged = nudged
    self.iteration = iteration
    self.verdict = verdict
    self.pendingLine = pendingLine
  }
}

// MARK: - Attention

public nonisolated enum WorkflowUserAction: String, Equatable, Sendable, Codable, CaseIterable {
  case accept
  case acceptWithVerdict = "accept-with-verdict"
  case askAgain = "ask-again"
  case keepWaiting = "keep-waiting"
  case skip
  case cancel
  case relaunch
  case retry
  case focusPane = "focus-pane"
}

/// Why a run stopped to ask the user, and what it offers. The UI and the
/// CLI render `actions` verbatim; policy lives in the machine only.
public nonisolated struct WorkflowAttention: Equatable, Sendable, Codable {
  public enum Reason: String, Equatable, Sendable, Codable {
    case provisionalDelivery = "provisional_delivery"
    case roleBlocked = "role_blocked"
    case roleGone = "role_gone"
    case deliveryTimeout = "delivery_timeout"
    case noDeliveryAfterIdle = "no_delivery_after_idle"
    case launchFailed = "launch_failed"
    case injectionFailed = "injection_failed"
    case commandFailed = "command_failed"
    case waitTimeout = "wait_timeout"
  }

  public var reason: Reason
  public var message: String
  public var stepID: String
  public var role: String?
  public var ordinal: Int?
  public var actions: [WorkflowUserAction]
  public var issues: [String]

  public init(
    reason: Reason,
    message: String,
    stepID: String,
    role: String? = nil,
    ordinal: Int? = nil,
    actions: [WorkflowUserAction],
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

  enum CodingKeys: String, CodingKey {
    case reason
    case message
    case stepID = "step_id"
    case role
    case ordinal
    case actions
    case issues
  }
}

// MARK: - Status and phase

public nonisolated enum WorkflowRunStatus: Equatable, Sendable, Codable {
  case running
  case needsAttention(WorkflowAttention)
  case completed
  case cancelled
  case skipped(step: String, dependent: String)
  case iterationLimitReached(loop: String)
  case failed(step: String, reason: String)
  case interrupted

  public var isTerminal: Bool {
    switch self {
    case .running, .needsAttention: return false
    case .completed, .cancelled, .skipped, .iterationLimitReached, .failed, .interrupted: return true
    }
  }

  public var attention: WorkflowAttention? {
    if case .needsAttention(let attention) = self { return attention }
    return nil
  }

  /// Stable snake_case name for records, the index, and the CLI.
  public var stateName: String {
    switch self {
    case .running: return "running"
    case .needsAttention: return "needs_attention"
    case .completed: return "completed"
    case .cancelled: return "cancelled"
    case .skipped: return "skipped"
    case .iterationLimitReached: return "iteration_limit_reached"
    case .failed: return "failed"
    case .interrupted: return "interrupted"
    }
  }

  enum CodingKeys: String, CodingKey {
    case state
    case step
    case dependent
    case loop
    case reason
    case attention
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let state = try container.decode(String.self, forKey: .state)
    switch state {
    case "running":
      self = .running
    case "needs_attention":
      self = .needsAttention(try container.decode(WorkflowAttention.self, forKey: .attention))
    case "completed":
      self = .completed
    case "cancelled":
      self = .cancelled
    case "skipped":
      self = .skipped(
        step: try container.decode(String.self, forKey: .step),
        dependent: try container.decode(String.self, forKey: .dependent))
    case "iteration_limit_reached":
      self = .iterationLimitReached(loop: try container.decode(String.self, forKey: .loop))
    case "failed":
      self = .failed(
        step: try container.decode(String.self, forKey: .step),
        reason: try container.decode(String.self, forKey: .reason))
    case "interrupted":
      self = .interrupted
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .state, in: container, debugDescription: "unknown run state \(state)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(stateName, forKey: .state)
    switch self {
    case .needsAttention(let attention):
      try container.encode(attention, forKey: .attention)
    case .skipped(let step, let dependent):
      try container.encode(step, forKey: .step)
      try container.encode(dependent, forKey: .dependent)
    case .iterationLimitReached(let loop):
      try container.encode(loop, forKey: .loop)
    case .failed(let step, let reason):
      try container.encode(step, forKey: .step)
      try container.encode(reason, forKey: .reason)
    case .running, .completed, .cancelled, .interrupted:
      break
    }
  }
}

/// What the run is waiting on right now. Survives an attention: the
/// status flips to `needsAttention` while the phase keeps saying which
/// wait was interrupted, so `keepWaiting` knows what to resume.
public nonisolated enum WorkflowRunPhase: Equatable, Sendable {
  case idle
  case waitingForRole(role: String, ordinal: Int)
  case injecting(ordinal: Int)
  case launching(ordinal: Int)
  case waitingForDelivery(ordinal: Int)
  case waitingForState(role: String, until: WorkflowWaitCondition)
  case runningCommand(stepID: String)
  case finished

  public var name: String {
    switch self {
    case .idle: return "idle"
    case .waitingForRole: return "waiting_for_role"
    case .injecting: return "injecting"
    case .launching: return "launching"
    case .waitingForDelivery: return "waiting_for_delivery"
    case .waitingForState: return "waiting_for_state"
    case .runningCommand: return "running_command"
    case .finished: return "finished"
    }
  }
}

// MARK: - Run

/// The whole run as a value. The machine owns and mutates it; the engine
/// reads it for display and derives `run.json` from `record`.
public nonisolated struct WorkflowRunState: Equatable, Sendable {
  public var configuration: WorkflowRunConfiguration
  /// Live view of the role bindings; a `launch` role gains its pane here.
  public var bindings: [String: WorkflowRoleBinding]
  public var status: WorkflowRunStatus
  public var phase: WorkflowRunPhase
  /// Keyed by step id. A loop body step re-entered on a later iteration
  /// overwrites its earlier record.
  public var steps: [String: WorkflowStepRecord]
  public var state: [String: WorkflowValue]
  /// Keyed by delivery name; latest wins.
  public var deliveries: [String: WorkflowDeliveryRecord]
  /// `run:` step outputs keyed by step id: `exit-code`, `stdout`,
  /// `stdout-path`.
  public var stepOutputs: [String: WorkflowValue]
  public var activations: [Int: WorkflowActivation]
  /// Last observed agent state per role (`idle` / `working` / `blocked` /
  /// `finished` / `gone`), as the engine reports it.
  public var roleStates: [String: String]
  public var currentOrdinal: Int?
  public var nextOrdinal: Int
  public var currentStepID: String?
  public var loopIteration: Int?
  public var finishedAt: Date?
  public var cursor: WorkflowCursor
  /// Human-readable lines appended by the last transition. The engine
  /// drains and persists them.
  public var log: [String]

  public init(configuration: WorkflowRunConfiguration) {
    self.configuration = configuration
    self.bindings = configuration.bindings
    self.status = .running
    self.phase = .idle
    self.steps = [:]
    self.state = Dictionary(uniqueKeysWithValues: configuration.definition.state.map { ($0.name, $0.initial) })
    self.deliveries = [:]
    self.stepOutputs = [:]
    self.activations = [:]
    self.roleStates = [:]
    self.currentOrdinal = nil
    self.nextOrdinal = 1
    self.currentStepID = nil
    self.loopIteration = nil
    self.finishedAt = nil
    self.cursor = WorkflowCursor()
    self.log = []
  }

  public var id: UUID { configuration.id }
  public var definition: WorkflowDefinition { configuration.definition }

  public var currentActivation: WorkflowActivation? {
    guard let currentOrdinal else { return nil }
    return activations[currentOrdinal]
  }

  public var currentStep: WorkflowStep? {
    guard let currentStepID else { return nil }
    return definition.step(id: currentStepID)
  }

  public func paneID(for role: String) -> PaneID? {
    bindings[role]?.paneID
  }
}
