import Foundation

/// The `run.json` snapshot: everything about a run worth reading back
/// after the fact, and nothing secret. Tokens, environment values, and
/// rendered launch commands never appear here. Keys are snake_case and
/// dates ISO-8601, per the persistence invariants.
public nonisolated struct WorkflowRunRecord: Equatable, Sendable, Codable {
  public static let currentVersion = 1

  /// An activation without its token.
  public struct Activation: Equatable, Sendable, Codable {
    public var ordinal: Int
    public var stepID: String
    public var role: String
    public var paneID: PaneID?
    public var delivery: String
    public var state: WorkflowActivationState
    public var issues: [String]
    public var deadline: Date?
    public var nudged: Bool
    public var iteration: Int?
    public var verdict: String?

    public init(_ activation: WorkflowActivation) {
      ordinal = activation.ordinal
      stepID = activation.stepID
      role = activation.role
      paneID = activation.paneID
      delivery = activation.delivery
      state = activation.state
      issues = activation.issues
      deadline = activation.deadline
      nudged = activation.nudged
      iteration = activation.iteration
      verdict = activation.verdict
    }

    enum CodingKeys: String, CodingKey {
      case ordinal
      case stepID = "step_id"
      case role
      case paneID = "pane_id"
      case delivery
      case state
      case issues
      case deadline
      case nudged
      case iteration
      case verdict
    }
  }

  public var version: Int
  public var id: UUID
  public var workflowID: String
  public var workflowName: String
  public var status: WorkflowRunStatus
  public var phase: String
  public var source: WorkflowRunSource
  public var bindings: [String: WorkflowRoleBinding]
  public var inputs: [String: WorkflowValue]
  public var state: [String: WorkflowValue]
  public var skippedSteps: [String]
  public var steps: [String: WorkflowStepRecord]
  public var deliveries: [String: WorkflowDeliveryRecord]
  public var stepOutputs: [String: WorkflowValue]
  /// Keyed by ordinal, spelled as a string for JSON.
  public var activations: [String: Activation]
  public var currentOrdinal: Int?
  public var nextOrdinal: Int
  public var currentStepID: String?
  public var loopIteration: Int?
  public var initiatorPaneID: PaneID?
  public var runDirectory: String
  public var cliCommand: String
  public var startedAt: Date
  public var finishedAt: Date?

  enum CodingKeys: String, CodingKey {
    case version
    case id
    case workflowID = "workflow_id"
    case workflowName = "workflow_name"
    case status
    case phase
    case source
    case bindings
    case inputs
    case state
    case skippedSteps = "skipped_steps"
    case steps
    case deliveries
    case stepOutputs = "step_outputs"
    case activations
    case currentOrdinal = "current_ordinal"
    case nextOrdinal = "next_ordinal"
    case currentStepID = "current_step_id"
    case loopIteration = "loop_iteration"
    case initiatorPaneID = "initiator_pane_id"
    case runDirectory = "run_directory"
    case cliCommand = "cli_command"
    case startedAt = "started_at"
    case finishedAt = "finished_at"
  }

  public init(_ run: WorkflowRunState) {
    let configuration = run.configuration
    version = Self.currentVersion
    id = configuration.id
    workflowID = configuration.definition.id
    workflowName = configuration.definition.name
    status = run.status
    phase = run.phase.name
    source = configuration.source
    bindings = run.bindings
    inputs = configuration.inputs
    state = run.state
    skippedSteps = configuration.skippedSteps.sorted()
    steps = run.steps
    deliveries = run.deliveries
    stepOutputs = run.stepOutputs
    activations = Dictionary(uniqueKeysWithValues: run.activations.map { (String($0.key), Activation($0.value)) })
    currentOrdinal = run.currentOrdinal
    nextOrdinal = run.nextOrdinal
    currentStepID = run.currentStepID
    loopIteration = run.loopIteration
    initiatorPaneID = configuration.initiatorPaneID
    runDirectory = configuration.runDirectory
    cliCommand = configuration.cliCommand
    startedAt = configuration.startedAt
    finishedAt = run.finishedAt
  }

  /// Whether the record describes a run that stopped for good. A run
  /// found alive on disk at app start is `interrupted`, not resumed.
  public var isTerminal: Bool { status.isTerminal }

  /// Pretty-printed, sorted keys, ISO-8601 dates — the shape `run.json`
  /// and `index.json` are written in.
  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  public static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

extension WorkflowRunState {
  public var record: WorkflowRunRecord { WorkflowRunRecord(self) }
}
