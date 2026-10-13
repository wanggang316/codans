import CodansCore
import Foundation
import os

/// Everything the engine reaches outside itself, as closures so tests
/// run it against fakes and an injectable clock. The app wires each one
/// to the live client it stands for in `CodansApp`.
struct WorkflowEngineDependencies {
  var now: @MainActor () -> Date = { Date() }
  var makeToken: @MainActor () -> String = { WorkflowEngine.randomToken() }
  /// Types one line plus Enter; `false` when the pane has no surface.
  var sendLine: @MainActor (PaneID, String) -> Bool
  /// Starts a `launch` role from its frozen profile and returns the pane.
  var launch: @MainActor (WorkflowLaunchRequest, WorkflowRunSource, AgentProfile) async throws -> PaneID
  /// `run:` step: shell command, working directory, extra environment,
  /// timeout in seconds.
  var runCommand: @Sendable (String, String, [String: String], Int) async -> CommandOutcome
  var closePane: @MainActor (PaneID) -> Void
  var focusPane: @MainActor (PaneID) -> Void
  var paneExists: @MainActor (PaneID) -> Bool
  /// `nil` when no agent is bound to the pane.
  var agentState: @MainActor (PaneID) -> AgentStateStore.AgentRuntimeState?
  /// Inbox notification: title, body, the pane it concerns.
  var notify: @MainActor (String, String, PaneID?) -> Void
  var profile: @MainActor (UUID) -> AgentProfile?
  var rememberBinding: @MainActor (WorkflowBindingMemory) -> Void
  /// How long `idle` must hold before a role counts as idle.
  var idleHoldSeconds: TimeInterval = 2
  /// How long `blocked` must hold before it becomes an attention.
  var blockedHoldSeconds: TimeInterval = 30
  var pollInterval: Duration = .milliseconds(200)
}

/// Owns the active runs and interprets the machine's effects against the
/// app: panes, agent state, subprocesses, files, notifications. Each run
/// has one serial effect queue; long waits (role polling, watchdogs,
/// launches, commands) run in their own tasks and report back as events
/// through `apply`, on the main actor.
@MainActor
@Observable
final class WorkflowEngine {
  private(set) var sessions: [UUID: WorkflowRunSession] = [:]
  /// Ended runs, oldest first, kept for status queries this app lifetime.
  private(set) var finishedSessions: [WorkflowRunSession] = []

  let dependencies: WorkflowEngineDependencies
  let registry: WorkflowActivationRegistry
  let logger = Logger(subsystem: "com.gumpw.codans", category: "workflow")

  /// Every task the engine spawns is owned by a session, whose own
  /// explicit deinit cancels it; the engine holds no tasks itself.
  init(registry: WorkflowActivationRegistry, dependencies: WorkflowEngineDependencies) {
    self.registry = registry
    self.dependencies = dependencies
  }

  // MARK: - Public API

  var activeRuns: [WorkflowRunSession] {
    sessions.values.sorted { $0.run.configuration.startedAt < $1.run.configuration.startedAt }
  }

  var finishedRuns: [WorkflowRunSession] { finishedSessions }

  func session(for runID: UUID) -> WorkflowRunSession? {
    sessions[runID] ?? finishedSessions.first { $0.id == runID }
  }

  func run(for runID: UUID) -> WorkflowRunState? {
    session(for: runID)?.run
  }

  /// Lays the run directory out, writes the definition copy and the
  /// initial record, starts the machine and runs its first effects to
  /// completion (so a self-initiated instruction file exists before the
  /// caller reads the path back).
  func start(
    configuration: WorkflowRunConfiguration, entry: WorkflowCatalogEntry
  ) async throws -> (runID: UUID, selfInitiated: WorkflowSelfInitiatedTask?) {
    let store = WorkflowRunStore(runDirectory: URL(fileURLWithPath: configuration.runDirectory, isDirectory: true))
    try WorkflowRunStore.ensureWorktreeLayout(
      worktreeRoot: URL(fileURLWithPath: configuration.source.worktreePath, isDirectory: true))
    try store.writeDefinitionCopy(yaml: entry.yaml)
    let (machine, effects, selfInitiated) = WorkflowMachine.start(
      configuration, now: dependencies.now(), makeToken: dependencies.makeToken)
    try store.writeRecord(machine.run.record)
    let session = WorkflowRunSession(entry: entry, store: store, machine: machine)
    session.pendingLog = machine.run.log
    sessions[configuration.id] = session
    registry.join(panes: configuration.bindings.values.compactMap(\.paneID), runID: configuration.id)
    noteAttention(session, previous: nil)
    enqueue(effects, on: session)
    await drain(session)
    return (configuration.id, selfInitiated)
  }

  /// Takes a delivery and returns once it is on disk (or refused). The
  /// record is `nil` when the machine refused it or the write failed.
  func deliver(
    runID: UUID, ordinal: Int, token: String?, allowManual: Bool, force: Bool, body: String, verdict: String?
  ) async -> (outcome: WorkflowDeliveryOutcome, delivery: WorkflowDeliveryRecord?) {
    guard let session = sessions[runID] else {
      return (.rejected(code: "RUN_NOT_FOUND", message: "no active run \(runID.uuidString)"), nil)
    }
    let previous = session.machine.run.status.attention
    let (outcome, effects) = session.machine.deliver(
      ordinal: ordinal, token: token, allowManual: allowManual, force: force, body: body, verdict: verdict,
      now: dependencies.now())
    afterTransition(session, previousAttention: previous)
    enqueue(effects, on: session)
    // Wait until the queue is empty, not just until this job ran: the
    // persisted delivery applies `deliveryPersisted`, whose effects (the
    // next step, or the run finishing) are queued behind it, and the CLI
    // caller reads the run's state right after `deliver` returns.
    await drain(session)
    let name = session.machine.run.activations[ordinal]?.delivery
    let record = name.flatMap { session.machine.run.deliveries[$0] }.flatMap { $0.ordinal == ordinal ? $0 : nil }
    switch outcome {
    case .accepted, .provisional:
      guard let record else {
        return (.rejected(code: "DELIVERY_PERSIST_FAILED", message: "the delivery could not be written"), nil)
      }
      return (outcome, record)
    case .rejected:
      return (outcome, nil)
    }
  }

  /// A user action on a run that needs attention. `focusPane` is handled
  /// here: the machine treats it as informational.
  @discardableResult
  func resolve(runID: UUID, action: WorkflowUserAction, verdict: String?) -> Bool {
    guard let session = sessions[runID] else { return false }
    if action == .focusPane {
      if let paneID = session.focusPaneID { dependencies.focusPane(paneID) }
      return true
    }
    apply(.user(action, verdict: verdict), to: session)
    return true
  }

  @discardableResult
  func cancel(runID: UUID) -> Bool {
    guard let session = sessions[runID] else { return false }
    // Cancelling the task running a `run:` step makes the runner's timeout
    // race return at once, which walks its SIGTERM → SIGKILL ladder.
    session.commandTask?.cancel()
    apply(.user(.cancel, verdict: nil), to: session)
    return true
  }

  // MARK: - Events

  /// Feeds one event to the run's machine and queues the effects.
  func apply(_ event: WorkflowRunEvent, to session: WorkflowRunSession) {
    guard sessions[session.id] != nil else { return }
    let previous = session.machine.run.status.attention
    let effects = session.machine.apply(event, now: dependencies.now(), makeToken: dependencies.makeToken)
    afterTransition(session, previousAttention: previous)
    enqueue(effects, on: session)
  }

  private func afterTransition(_ session: WorkflowRunSession, previousAttention: WorkflowAttention?) {
    session.pendingLog += session.machine.run.log
    session.refresh()
    noteAttention(session, previous: previousAttention)
  }

  /// Entering `needsAttention` (or moving to a different attention) is
  /// what the user has to hear about.
  private func noteAttention(_ session: WorkflowRunSession, previous: WorkflowAttention?) {
    guard let attention = session.machine.run.status.attention, attention != previous else { return }
    let run = session.machine.run
    let paneID = attention.role.flatMap { run.paneID(for: $0) } ?? run.configuration.initiatorPaneID
    dependencies.notify("Workflow · \(run.definition.name)", attention.message, paneID)
  }

  // MARK: - Queue

  /// Appends `effects` as one job behind everything queued for the run.
  @discardableResult
  func enqueue(_ effects: [WorkflowEffect], on session: WorkflowRunSession) -> Task<Void, Never> {
    let previous = session.queueTail
    let job = Task { @MainActor [weak self] in
      await previous?.value
      guard let self else { return }
      for effect in effects {
        await self.perform(effect, on: session)
      }
    }
    session.queueTail = job
    session.queueGeneration += 1
    return job
  }

  /// Awaits the queue until no job is left, including jobs enqueued by
  /// the ones awaited.
  func drain(_ session: WorkflowRunSession) async {
    while let tail = session.queueTail {
      let generation = session.queueGeneration
      await tail.value
      if session.queueGeneration == generation { return }
    }
  }

  // MARK: - Finish

  func finish(_ session: WorkflowRunSession, status: WorkflowRunStatus) async {
    session.cancelTimers()
    await persistRecord(session)
    let record = session.machine.run.record
    let root = URL(fileURLWithPath: session.run.configuration.source.worktreePath, isDirectory: true)
    do {
      _ = try await Task.detached { try WorkflowRunStore.index(record, worktreeRoot: root) }.value
    } catch {
      logger.error("run index failed: \(String(describing: error), privacy: .public)")
    }
    registry.release(runID: session.id)
    sessions[session.id] = nil
    finishedSessions.append(session)
    let run = session.machine.run
    let paneID = run.configuration.initiatorPaneID ?? run.bindings.values.compactMap(\.paneID).first
    dependencies.notify("Workflow · \(run.definition.name)", Self.finishMessage(status), paneID)
  }

  static func finishMessage(_ status: WorkflowRunStatus) -> String {
    switch status {
    case .completed: return "completed"
    case .cancelled: return "cancelled"
    case .skipped(let step, let dependent): return "ended: \(step) was skipped and \(dependent) needs its delivery"
    case .iterationLimitReached(let loop): return "ended: loop \(loop) hit its iteration limit"
    case .failed(let step, let reason): return "failed at \(step): \(reason)"
    case .interrupted: return "interrupted"
    case .running, .needsAttention: return status.stateName
    }
  }

  // MARK: - Helpers

  static func randomToken() -> String {
    (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
  }

  /// The environment a `run:` step sees: the few variables a shell needs
  /// from this process, the socket so `codans` inside the command reaches
  /// this app, then the step's own.
  nonisolated static func commandEnvironment(
    step: [String: String],
    socketPath: String,
    process: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var environment: [String: String] = [:]
    for key in ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"] {
      if let value = process[key] { environment[key] = value }
    }
    environment[CodansEnvironment.Key.socketPath.rawValue] = socketPath
    environment.merge(step) { _, stepValue in stepValue }
    return environment
  }
}
