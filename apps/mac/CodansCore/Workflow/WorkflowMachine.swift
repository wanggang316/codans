import Foundation

// MARK: - Events

public nonisolated enum WorkflowWatchdogSignal: Equatable, Sendable {
  /// The role went idle and `idle_grace` passed without a delivery.
  case idleGraceElapsed
  /// `expect.timeout-minutes` ran out.
  case deadlineReached
}

/// What the outside world reports back. Each answers an effect; stale or
/// out-of-phase events are ignored so a late report can never move the
/// run onto the wrong step.
public nonisolated enum WorkflowRunEvent: Equatable, Sendable {
  case roleIdle(role: String)
  case roleBlocked(role: String)
  case roleGone(role: String)
  case roleExited(role: String)
  case waitTimedOut(role: String)
  case injected(ordinal: Int)
  case injectionFailed(ordinal: Int, reason: String)
  case launched(ordinal: Int, paneID: PaneID)
  case launchFailed(ordinal: Int, reason: String)
  case commandFinished(
    stepID: String, exitCode: Int?, stdout: String, stdoutPath: String, timedOut: Bool, spawnFailure: String?)
  case deliveryPersisted(ordinal: Int, path: String, latestPath: String)
  case deliveryPersistFailed(ordinal: Int, reason: String)
  case watchdog(ordinal: Int, WorkflowWatchdogSignal)
  case user(WorkflowUserAction, verdict: String?)
}

// MARK: - Effects

/// A `launch` role to start. `environment` carries the activation token
/// and the run / role hints; the engine merges it into the profile's own.
public nonisolated struct WorkflowLaunchRequest: Equatable, Sendable {
  public var role: String
  public var ordinal: Int
  public var profileID: UUID
  public var prompt: String
  public var placement: WorkflowRole.Placement
  public var direction: ScriptSplitDirection
  public var background: Bool
  public var anchorPaneID: PaneID?
  public var environment: [String: String]

  public init(
    role: String,
    ordinal: Int,
    profileID: UUID,
    prompt: String,
    placement: WorkflowRole.Placement,
    direction: ScriptSplitDirection,
    background: Bool,
    anchorPaneID: PaneID?,
    environment: [String: String]
  ) {
    self.role = role
    self.ordinal = ordinal
    self.profileID = profileID
    self.prompt = prompt
    self.placement = placement
    self.direction = direction
    self.background = background
    self.anchorPaneID = anchorPaneID
    self.environment = environment
  }
}

/// What the engine must do next. Effects are the machine's only output;
/// the engine answers the ones that wait with a `WorkflowRunEvent`.
public nonisolated enum WorkflowEffect: Equatable, Sendable {
  /// Answered with `roleIdle` / `roleBlocked` / `roleGone` / `roleExited`
  /// / `waitTimedOut`.
  case awaitRole(role: String, paneID: PaneID, until: WorkflowWaitCondition, timeoutMinutes: Int?)
  case cancelRoleWait(role: String)
  /// Registers a token. A `launch` role opens with `paneID == nil` and is
  /// opened again with the pane once `launched` arrives.
  case openActivation(ordinal: Int, paneID: PaneID?, token: String)
  case revokeActivation(ordinal: Int)
  /// Writes `instructions/<step>.<ordinal>.md`; the path is deterministic
  /// (`WorkflowRunLayout`) so the pointer line is already rendered.
  case materializeInstruction(ordinal: Int, stepID: String, text: String)
  /// One line plus Enter. Answered with `injected` / `injectionFailed`.
  case inject(paneID: PaneID, ordinal: Int, line: String)
  /// Answered with `launched` / `launchFailed`.
  case launch(WorkflowLaunchRequest)
  /// Answered with `commandFinished`.
  case runCommand(
    stepID: String, ordinal: Int, command: String, workingDirectory: String, environment: [String: String],
    timeoutSeconds: Int)
  case armWatchdog(ordinal: Int, idleGraceSeconds: Int, deadline: Date?)
  case disarmWatchdog(ordinal: Int)
  case notify(title: String, body: String)
  case closePane(paneID: PaneID, role: String)
  /// Answered with `deliveryPersisted` / `deliveryPersistFailed`.
  case persistDelivery(ordinal: Int, name: String, body: String, verdict: String?, provisional: Bool)
  case persistRecord
  case finished(WorkflowRunStatus)
}

/// The task handed back to the initiating agent instead of typed into its
/// pane, when the run's first step is a `message` to the pane that
/// started it.
public nonisolated struct WorkflowSelfInitiatedTask: Equatable, Sendable {
  public var stepID: String
  public var ordinal: Int
  public var line: String
  public var instructionPath: String?
  public var completionCommand: String?

  public init(stepID: String, ordinal: Int, line: String, instructionPath: String?, completionCommand: String?) {
    self.stepID = stepID
    self.ordinal = ordinal
    self.line = line
    self.instructionPath = instructionPath
    self.completionCommand = completionCommand
  }
}

public nonisolated enum WorkflowDeliveryOutcome: Equatable, Sendable {
  /// Clean; the delivery is being persisted and the step will complete.
  case accepted
  /// Persisted, then held for the user; `issues` says what was missing.
  case provisional(issues: [String])
  /// Refused; nothing changed. `code` is a `CLIErrorCode` name.
  case rejected(code: String, message: String)
}

// MARK: - Completion command

/// The one place the `deliver` invocation is spelled: the typed completion
/// suffix, the launch prompt's protocol paragraph, and the nudge all use
/// it, so an agent sees the same command everywhere.
public nonisolated enum WorkflowCompletionCommand {
  public static func render(cli: String, token: String, verdicts: [String]?) -> String {
    var command = "\(CodansEnvironment.Key.workflowToken.rawValue)=\(token) \(cli) workflow deliver"
    if let verdicts, !verdicts.isEmpty {
      command += " --verdict \(verdicts.joined(separator: "|"))"
    }
    return command + " -"
  }

  /// Appended to a typed line.
  public static func suffix(command: String) -> String {
    " — finish with: \(command)"
  }

  /// Appended to a launch prompt.
  public static func prompt(command: String) -> String {
    "\n\nWhen you are done, deliver your result by running exactly: \(command)  (with the body on stdin)"
  }

  public static func nudgeLine(command: String) -> String {
    "[codans] When your work is complete, deliver it with: \(command)"
  }

  public static func askAgainLine(issues: [String], command: String) -> String {
    if issues.isEmpty {
      return "[codans] No delivery was received. When your work is complete, deliver it with: \(command)"
    }
    return "[codans] Your delivery was incomplete: \(issues.joined(separator: "; ")). Deliver again with: \(command)"
  }
}

// MARK: - Machine

/// The pure run reducer. No I/O, clock, or randomness: `now` and
/// `makeToken` are injected on every call, and the outside world is only
/// ever reached through the returned effects.
public nonisolated struct WorkflowMachine: Equatable, Sendable {
  public internal(set) var run: WorkflowRunState

  /// Largest `stdout` kept in `steps.<id>.outputs`; the full text is on
  /// disk at `stdout-path`.
  public static let maximumContextStdoutBytes = 64 * 1024

  /// One reducer call: what it may consult and what it accumulates.
  struct Transition {
    let now: Date
    let makeToken: () -> String
    var effects: [WorkflowEffect] = []
    var selfInitiated: WorkflowSelfInitiatedTask?
    /// `true` only while entering the run's first outside-world step.
    var allowSelfInitiation = false
  }

  public static func start(
    _ configuration: WorkflowRunConfiguration,
    now: Date,
    makeToken: () -> String
  ) -> (machine: WorkflowMachine, effects: [WorkflowEffect], selfInitiated: WorkflowSelfInitiatedTask?) {
    var machine = WorkflowMachine(run: WorkflowRunState(configuration: configuration))
    var selfInitiated: WorkflowSelfInitiatedTask?
    let effects = machine.transition(now: now, makeToken: makeToken) { machine, transition in
      transition.allowSelfInitiation = true
      machine.log("start: \(configuration.definition.name) (\(configuration.definition.id))", &transition)
      machine.proceed(&transition)
      selfInitiated = transition.selfInitiated
    }
    return (machine, effects, selfInitiated)
  }

  public mutating func apply(_ event: WorkflowRunEvent, now: Date, makeToken: () -> String) -> [WorkflowEffect] {
    transition(now: now, makeToken: makeToken) { machine, transition in
      guard !machine.run.status.isTerminal else { return }
      machine.handle(event, &transition)
    }
  }

  /// Records the agent state the engine last observed for a role, for
  /// `roles.<role>.state`.
  public mutating func observe(role: String, state: String) {
    run.roleStates[role] = state
  }

  /// Runs `body` as one transition: clears the log, collects effects, and
  /// appends `persistRecord` when anything persisted changed, plus
  /// `finished` when the run just ended.
  mutating func transition(
    now: Date,
    makeToken: () -> String,
    _ body: (inout WorkflowMachine, inout Transition) -> Void
  ) -> [WorkflowEffect] {
    run.log = []
    var before = run
    before.log = []
    let wasTerminal = run.status.isTerminal
    var effects = withoutActuallyEscaping(makeToken) { makeToken -> [WorkflowEffect] in
      var transition = Transition(now: now, makeToken: makeToken)
      body(&self, &transition)
      return transition.effects
    }
    var after = run
    after.log = []
    if after != before {
      effects.append(.persistRecord)
    }
    if run.status.isTerminal, !wasTerminal {
      effects.append(.finished(run.status))
    }
    return effects
  }

  // MARK: - Shared helpers

  mutating func log(_ message: String, _ transition: inout Transition) {
    run.log.append("[\(Self.iso(transition.now))] \(message)")
  }

  static func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  mutating func mintOrdinal() -> Int {
    let ordinal = run.nextOrdinal
    run.nextOrdinal += 1
    run.currentOrdinal = ordinal
    return ordinal
  }

  /// Marks the run finished with a terminal status.
  mutating func finish(_ status: WorkflowRunStatus, _ transition: inout Transition) {
    run.status = status
    run.phase = .finished
    run.finishedAt = transition.now
    run.currentOrdinal = nil
    log("finished: \(status.stateName)", &transition)
  }

  mutating func fail(step: WorkflowStep, reason: String, _ transition: inout Transition) {
    finishStep(step.id, outcome: .failure, &transition)
    log("step \(step.id): failed — \(reason)", &transition)
    finish(.failed(step: step.id, reason: reason), &transition)
  }

  mutating func raiseAttention(_ attention: WorkflowAttention, _ transition: inout Transition) {
    run.status = .needsAttention(attention)
    log("attention: \(attention.reason.rawValue) — \(attention.message)", &transition)
  }

  /// An attention for the current step, with the role and ordinal filled
  /// in from the run.
  func attention(
    _ reason: WorkflowAttention.Reason,
    message: String,
    actions: [WorkflowUserAction],
    issues: [String] = []
  ) -> WorkflowAttention {
    WorkflowAttention(
      reason: reason,
      message: message,
      stepID: run.currentStepID ?? "",
      role: run.currentStep?.role,
      ordinal: run.currentOrdinal,
      actions: actions,
      issues: issues
    )
  }

  // MARK: - Step records

  mutating func beginStep(_ step: WorkflowStep, ordinal: Int?, _ transition: inout Transition) {
    run.currentStepID = step.id
    run.loopIteration = run.cursor.iteration
    run.steps[step.id] = WorkflowStepRecord(
      stepID: step.id,
      startedAt: transition.now,
      iteration: run.cursor.iteration,
      ordinal: ordinal
    )
  }

  mutating func finishStep(_ stepID: String, outcome: WorkflowStepOutcome, _ transition: inout Transition) {
    var record = run.steps[stepID] ?? WorkflowStepRecord(stepID: stepID, startedAt: transition.now)
    record.outcome = outcome
    record.finishedAt = transition.now
    run.steps[stepID] = record
    log("step \(stepID): \(outcome.rawValue)", &transition)
  }

  // MARK: - Rendering

  /// Renders a template against the current context; a failure ends the
  /// run and returns `nil`.
  mutating func render(_ template: WorkflowTemplate, for step: WorkflowStep, _ transition: inout Transition)
    -> String?
  {
    do {
      return try template.render(in: context())
    } catch {
      fail(step: step, reason: error.message, &transition)
      return nil
    }
  }

  mutating func evaluate(_ condition: WorkflowExpression, for step: WorkflowStep, _ transition: inout Transition)
    -> Bool?
  {
    do {
      return try condition.evaluateCondition(in: context())
    } catch {
      fail(step: step, reason: error.message, &transition)
      return nil
    }
  }

  func completionCommand(for activation: WorkflowActivation) -> String {
    WorkflowCompletionCommand.render(
      cli: run.configuration.cliCommand,
      token: activation.token,
      verdicts: activation.expectation.verdicts
    )
  }
}
