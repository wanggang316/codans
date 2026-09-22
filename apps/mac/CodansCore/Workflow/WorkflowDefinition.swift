import Foundation

/// A parsed `<id>.workflow.yaml`. Pure data: the parser builds it, the
/// validator checks cross references, the run machine executes it. Nothing
/// here knows about files, panes, or agents beyond the names it declares.
///
/// The file name is the workflow id (as with GitHub Actions there is no
/// `id:` key); `name` is the display name.
public nonisolated struct WorkflowDefinition: Equatable, Sendable {
  public var id: String
  public var name: String
  public var description: String?
  public var inputs: [WorkflowInput]
  public var roles: [WorkflowRole]
  public var state: [WorkflowStateVariable]
  public var steps: [WorkflowStep]

  public init(
    id: String,
    name: String,
    description: String? = nil,
    inputs: [WorkflowInput] = [],
    roles: [WorkflowRole] = [],
    state: [WorkflowStateVariable] = [],
    steps: [WorkflowStep]
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.inputs = inputs
    self.roles = roles
    self.state = state
    self.steps = steps
  }

  /// `[a-z0-9][a-z0-9_.-]{0,63}` — the same shape for workflow ids, step ids,
  /// role names, delivery names, and verdicts.
  public static func isValidIdentifier(_ candidate: String) -> Bool {
    guard let first = candidate.unicodeScalars.first, candidate.count <= 64 else { return false }
    let firstIsLowerOrDigit =
      (first.value >= 0x61 && first.value <= 0x7A) || (first.value >= 0x30 && first.value <= 0x39)
    guard firstIsLowerOrDigit else { return false }
    return candidate.unicodeScalars.allSatisfy { scalar in
      (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
        || scalar == "_" || scalar == "-" || scalar == "."
    }
  }

  public func role(named name: String) -> WorkflowRole? {
    roles.first { $0.name == name }
  }

  public func input(named name: String) -> WorkflowInput? {
    inputs.first { $0.name == name }
  }

  /// Every step in document order, loop bodies inlined after their loop.
  public var flattenedSteps: [WorkflowStep] {
    var result: [WorkflowStep] = []
    func walk(_ steps: [WorkflowStep]) {
      for step in steps {
        result.append(step)
        if case .loop(_, _, let body) = step.verb { walk(body) }
      }
    }
    walk(steps)
    return result
  }

  public func step(id: String) -> WorkflowStep? {
    flattenedSteps.first { $0.id == id }
  }

  /// Whether any step executes a shell command — the property that decides
  /// if a repository-scoped file needs the user's trust before it can start.
  public var executesCommands: Bool {
    flattenedSteps.contains {
      if case .run = $0.verb { return true }
      return false
    }
  }
}

// MARK: - Inputs

public nonisolated struct WorkflowInput: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable, CaseIterable {
    case string
    case number
    case boolean
    case choice
  }

  public var name: String
  public var description: String?
  public var kind: Kind
  /// `required: true` in the file, or no `default` — either way the start
  /// sheet asks and the CLI needs `--input`.
  public var required: Bool
  public var defaultValue: WorkflowValue?
  /// `choice` only.
  public var options: [String]
  /// `number` only.
  public var min: Int?
  public var max: Int?

  public init(
    name: String,
    description: String? = nil,
    kind: Kind,
    required: Bool = false,
    defaultValue: WorkflowValue? = nil,
    options: [String] = [],
    min: Int? = nil,
    max: Int? = nil
  ) {
    self.name = name
    self.description = description
    self.kind = kind
    self.required = required
    self.defaultValue = defaultValue
    self.options = options
    self.min = min
    self.max = max
  }

  public var isRequired: Bool { required || defaultValue == nil }
}

// MARK: - Roles

public nonisolated struct WorkflowRole: Equatable, Sendable {
  public enum Source: String, Equatable, Sendable, CaseIterable {
    /// The pane the run was started from.
    case current
    /// codans launches a new agent from an Agent Profile.
    case launch
    /// An existing agent pane in the source worktree, chosen at start.
    case pick
  }

  public enum Placement: String, Equatable, Sendable, CaseIterable {
    case split
    case tab
  }

  public var name: String
  public var source: Source
  /// `launch` only: allow-list of agent kinds; `nil` means any launchable
  /// profile qualifies.
  public var agents: [AgentKind]?
  /// `launch` only: preferred profile display name. A remembered local
  /// binding wins over it.
  public var profile: String?
  /// `launch` only.
  public var placement: Placement
  public var direction: ScriptSplitDirection
  /// `launch` only: `true` never focuses the new pane.
  public var background: Bool

  public init(
    name: String,
    source: Source,
    agents: [AgentKind]? = nil,
    profile: String? = nil,
    placement: Placement = .split,
    direction: ScriptSplitDirection = .right,
    background: Bool = false
  ) {
    self.name = name
    self.source = source
    self.agents = agents
    self.profile = profile
    self.placement = placement
    self.direction = direction
    self.background = background
  }
}

// MARK: - State

public nonisolated struct WorkflowStateVariable: Equatable, Sendable {
  public var name: String
  /// The initial literal also fixes the variable's type for the run.
  public var initial: WorkflowValue

  public init(name: String, initial: WorkflowValue) {
    self.name = name
    self.initial = initial
  }
}

// MARK: - Steps

public nonisolated struct WorkflowStep: Equatable, Sendable {
  /// Explicit `id:` or a synthesized `step-<n>` (document order, loop bodies
  /// included). Unique across the definition.
  public var id: String
  /// `true` when the file spelled `id:`; only such steps may be referenced
  /// as `steps.<id>`.
  public var hasExplicitID: Bool
  public var name: String?
  /// `if:` guard. A step whose guard evaluates false is `skipped`.
  public var condition: WorkflowExpression?
  public var verb: WorkflowStepVerb
  /// Where the step sits in the file, for diagnostics (`steps[2].steps[0]`).
  public var path: String

  public init(
    id: String,
    hasExplicitID: Bool = true,
    name: String? = nil,
    condition: WorkflowExpression? = nil,
    verb: WorkflowStepVerb,
    path: String = ""
  ) {
    self.id = id
    self.hasExplicitID = hasExplicitID
    self.name = name
    self.condition = condition
    self.verb = verb
    self.path = path
  }

  /// What a list calls this step: its `name`, else its own id, else — for
  /// a step the parser had to number — what it does, so a run's step list
  /// never reads "step-4".
  public var displayName: String { name ?? (hasExplicitID ? id : verb.summary) }

  /// The role a step addresses, when it addresses one.
  public var role: String? {
    switch verb {
    case .message(let role, _, _), .launch(let role, _, _), .wait(let role, _, _), .close(let role):
      return role
    case .run(let run):
      return run.inRole
    case .notify, .set, .loop, .breakLoop, .continueLoop:
      return nil
    }
  }

  public var expectation: WorkflowExpectation? {
    switch verb {
    case .message(_, _, let expect), .launch(_, _, let expect):
      return expect
    default:
      return nil
    }
  }
}

public nonisolated indirect enum WorkflowStepVerb: Equatable, Sendable {
  case message(role: String, content: WorkflowMessageContent, expect: WorkflowExpectation?)
  case launch(role: String, prompt: WorkflowTemplate, expect: WorkflowExpectation?)
  case run(WorkflowRunCommand)
  case wait(role: String, until: WorkflowWaitCondition, timeoutMinutes: Int?)
  case notify(WorkflowTemplate)
  case close(role: String)
  /// Atomic assignments; every value is a template evaluated against the
  /// same pre-assignment state.
  case set([WorkflowAssignment])
  case loop(condition: WorkflowExpression, maxIterations: Int?, steps: [WorkflowStep])
  case breakLoop
  case continueLoop

  /// A short label for a step that has neither a name nor an explicit id.
  public var summary: String {
    switch self {
    case .message(let role, _, _): return "Message \(role)"
    case .launch(let role, _, _): return "Launch \(role)"
    case .run: return "Run command"
    case .wait(let role, let until, _): return "Wait for \(role) (\(until.rawValue))"
    case .notify: return "Notify"
    case .close(let role): return "Close \(role)"
    case .set(let assignments): return "Set " + assignments.map(\.name).joined(separator: ", ")
    case .loop: return "Loop"
    case .breakLoop: return "Break"
    case .continueLoop: return "Continue"
    }
  }

  /// The YAML key that names this verb, for diagnostics and logs.
  public var keyword: String {
    switch self {
    case .message: return "message"
    case .launch: return "launch"
    case .run: return "run"
    case .wait: return "wait"
    case .notify: return "notify"
    case .close: return "close"
    case .set: return "set"
    case .loop: return "while"
    case .breakLoop: return "break"
    case .continueLoop: return "continue"
    }
  }
}

public nonisolated enum WorkflowMessageContent: Equatable, Sendable {
  /// One line typed into the pane.
  case text(WorkflowTemplate)
  /// Multi-line, materialized to a file; only a pointer line is typed.
  case instruction(WorkflowTemplate)

  public var template: WorkflowTemplate {
    switch self {
    case .text(let template), .instruction(let template): return template
    }
  }
}

public nonisolated struct WorkflowRunCommand: Equatable, Sendable {
  public static let defaultTimeoutMinutes = 10

  public var command: WorkflowTemplate
  public var workingDirectory: WorkflowTemplate?
  public var env: [String: WorkflowTemplate]
  public var timeoutMinutes: Int
  public var continueOnError: Bool
  /// Type the command into this role's pane instead of running headless.
  public var inRole: String?

  public init(
    command: WorkflowTemplate,
    workingDirectory: WorkflowTemplate? = nil,
    env: [String: WorkflowTemplate] = [:],
    timeoutMinutes: Int = WorkflowRunCommand.defaultTimeoutMinutes,
    continueOnError: Bool = false,
    inRole: String? = nil
  ) {
    self.command = command
    self.workingDirectory = workingDirectory
    self.env = env
    self.timeoutMinutes = timeoutMinutes
    self.continueOnError = continueOnError
    self.inRole = inRole
  }
}

public nonisolated enum WorkflowWaitCondition: String, Equatable, Sendable, CaseIterable {
  case idle
  case blocked
  case exit
}

public nonisolated struct WorkflowAssignment: Equatable, Sendable {
  public var name: String
  public var value: WorkflowTemplate

  public init(name: String, value: WorkflowTemplate) {
    self.name = name
    self.value = value
  }
}

// MARK: - Expectation

public nonisolated struct WorkflowExpectation: Equatable, Sendable {
  public enum Format: String, Equatable, Sendable, CaseIterable {
    case markdown
    case text
    case json
  }

  public enum TimeoutPolicy: String, Equatable, Sendable, CaseIterable {
    case attention
    case skip
    case cancel
  }

  public static let minimumVerdicts = 2
  public static let maximumVerdicts = 4

  /// Output name; defaults to the step id.
  public var delivery: String
  public var format: Format
  /// Required headings for `markdown`.
  public var sections: [String]
  /// When set, `--verdict` is mandatory and must be one of these.
  public var verdicts: [String]?
  /// Hard cap; `nil` waits as long as the agent works.
  public var timeoutMinutes: Int?
  public var onTimeout: TimeoutPolicy
  /// `false` keeps a delivery that misses sections / format / verdict as
  /// provisional for the user to resolve; `true` rejects it outright.
  public var strict: Bool

  public init(
    delivery: String,
    format: Format = .markdown,
    sections: [String] = [],
    verdicts: [String]? = nil,
    timeoutMinutes: Int? = nil,
    onTimeout: TimeoutPolicy = .attention,
    strict: Bool = false
  ) {
    self.delivery = delivery
    self.format = format
    self.sections = sections
    self.verdicts = verdicts
    self.timeoutMinutes = timeoutMinutes
    self.onTimeout = onTimeout
    self.strict = strict
  }
}
