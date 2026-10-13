import Foundation

/// Step entry: walks the cursor through in-process steps (`set`, `notify`,
/// `while`, `break`, `continue`, false guards) and stops at the first
/// step that needs the outside world, leaving the run in a non-idle phase.
extension WorkflowMachine {
  /// Keeps entering steps while the run is idle. Every in-process step
  /// completes synchronously; an outside-world step leaves the phase
  /// non-idle and the loop stops there.
  mutating func proceed(_ transition: inout Transition) {
    while !run.status.isTerminal, run.phase == .idle {
      guard let step = run.cursor.currentStep(in: run.definition) else {
        if run.cursor.isInLoop {
          endOfLoopBody(&transition)
        } else {
          finish(.completed, &transition)
        }
        continue
      }
      enter(step, &transition)
    }
  }

  /// Finishes the current step in place and moves the cursor on, without
  /// entering the next step. `proceed` drives the loop.
  mutating func completeStep(_ step: WorkflowStep, outcome: WorkflowStepOutcome, _ transition: inout Transition) {
    finishStep(step.id, outcome: outcome, &transition)
    run.currentOrdinal = nil
    run.phase = .idle
    run.cursor.advance()
  }

  /// Finishes the current step and keeps going.
  mutating func complete(_ step: WorkflowStep, outcome: WorkflowStepOutcome, _ transition: inout Transition) {
    completeStep(step, outcome: outcome, &transition)
    proceed(&transition)
  }

  /// Re-runs the current step from its beginning (after a relaunch or a
  /// retry). Mints fresh ordinals and activations as a first entry would.
  mutating func reenterCurrentStep(_ transition: inout Transition) {
    guard let step = run.currentStep else { return }
    run.status = .running
    run.phase = .idle
    run.currentOrdinal = nil
    enter(step, &transition)
    proceed(&transition)
  }

  mutating func enter(_ step: WorkflowStep, _ transition: inout Transition) {
    beginStep(step, ordinal: nil, &transition)
    if run.configuration.skippedSteps.contains(step.id) {
      log("step \(step.id): skipped at start", &transition)
      completeStep(step, outcome: .skipped, &transition)
      return
    }
    if let condition = step.condition {
      guard let satisfied = evaluate(condition, for: step, &transition) else { return }
      if !satisfied {
        log("step \(step.id): skipped (condition false)", &transition)
        completeStep(step, outcome: .skipped, &transition)
        return
      }
    }
    switch step.verb {
    case .set(let assignments):
      enterSet(step, assignments, &transition)
    case .notify(let template):
      enterNotify(step, template, &transition)
    case .breakLoop:
      enterBreak(step, &transition)
    case .continueLoop:
      enterContinue(step, &transition)
    case .loop(let condition, let maxIterations, let body):
      enterLoop(step, condition: condition, maxIterations: maxIterations, body: body, &transition)
    case .message(let role, let content, let expect):
      enterMessage(step, role: role, content: content, expect: expect, &transition)
    case .launch(let role, let prompt, let expect):
      enterLaunch(step, role: role, prompt: prompt, expect: expect, &transition)
    case .run(let command):
      enterRun(step, command, &transition)
    case .wait(let role, let until, let timeoutMinutes):
      enterWait(step, role: role, until: until, timeoutMinutes: timeoutMinutes, &transition)
    case .close(let role):
      enterClose(step, role: role, &transition)
    }
  }

  // MARK: - In-process verbs

  private mutating func enterSet(
    _ step: WorkflowStep, _ assignments: [WorkflowAssignment], _ transition: inout Transition
  ) {
    let context = context()
    var updates: [String: WorkflowValue] = [:]
    for assignment in assignments {
      guard let declared = run.definition.state.first(where: { $0.name == assignment.name }) else {
        fail(step: step, reason: "state.\(assignment.name) is not declared", &transition)
        return
      }
      let value: WorkflowValue
      do {
        value = try assignment.value.renderValue(in: context)
      } catch {
        fail(step: step, reason: error.message, &transition)
        return
      }
      // The initial literal fixes the type; `null` is allowed everywhere
      // because a delivery's verdict may legitimately be absent.
      if !value.isNull, !declared.initial.isNull, value.typeName != declared.initial.typeName {
        fail(
          step: step,
          reason: "state.\(assignment.name) is a \(declared.initial.typeName), got \(value.typeName)",
          &transition)
        return
      }
      updates[assignment.name] = value
    }
    for (name, value) in updates {
      run.state[name] = value
    }
    completeStep(step, outcome: .success, &transition)
  }

  private mutating func enterNotify(
    _ step: WorkflowStep,
    _ template: WorkflowTemplate,
    _ transition: inout Transition
  ) {
    guard let body = render(template, for: step, &transition) else { return }
    transition.effects.append(.notify(title: "Workflow · \(run.definition.name)", body: body))
    completeStep(step, outcome: .success, &transition)
  }

  private mutating func enterBreak(_ step: WorkflowStep, _ transition: inout Transition) {
    guard let loop = run.cursor.enclosingLoop(in: run.definition) else {
      fail(step: step, reason: "break outside a loop", &transition)
      return
    }
    finishStep(step.id, outcome: .success, &transition)
    run.cursor.exitLoop()
    run.loopIteration = run.cursor.iteration
    finishStep(loop.id, outcome: .success, &transition)
  }

  private mutating func enterContinue(_ step: WorkflowStep, _ transition: inout Transition) {
    guard run.cursor.isInLoop else {
      fail(step: step, reason: "continue outside a loop", &transition)
      return
    }
    finishStep(step.id, outcome: .success, &transition)
    run.cursor.finishBody(in: run.definition)
  }

  private mutating func enterLoop(
    _ step: WorkflowStep,
    condition: WorkflowExpression,
    maxIterations: Int?,
    body: [WorkflowStep],
    _ transition: inout Transition
  ) {
    guard let satisfied = evaluate(condition, for: step, &transition) else { return }
    if !satisfied {
      completeStep(step, outcome: .success, &transition)
      return
    }
    // Without a cap, a body that never leaves the process would spin
    // forever inside one `apply`; refuse it up front.
    if maxIterations == nil, !Self.touchesOutsideWorld(body) {
      fail(step: step, reason: "loop without effects needs max-iterations", &transition)
      return
    }
    if let maxIterations, maxIterations < 1 {
      finish(.iterationLimitReached(loop: step.id), &transition)
      return
    }
    run.cursor.enterLoop()
    run.loopIteration = run.cursor.iteration
    log("step \(step.id): iteration 1", &transition)
  }

  /// The innermost loop body ran out of steps: re-check the condition and
  /// either go around again, leave the loop, or hit the cap.
  private mutating func endOfLoopBody(_ transition: inout Transition) {
    guard let loop = run.cursor.enclosingLoop(in: run.definition),
      case .loop(let condition, let maxIterations, _) = loop.verb
    else {
      run.cursor.exitLoop()
      return
    }
    guard let satisfied = evaluate(condition, for: loop, &transition) else { return }
    if !satisfied {
      run.cursor.exitLoop()
      run.loopIteration = run.cursor.iteration
      finishStep(loop.id, outcome: .success, &transition)
      return
    }
    let next = (run.cursor.iteration ?? 0) + 1
    if let maxIterations, next > maxIterations {
      finishStep(loop.id, outcome: .failure, &transition)
      finish(.iterationLimitReached(loop: loop.id), &transition)
      return
    }
    run.cursor.nextIteration()
    run.loopIteration = run.cursor.iteration
    log("step \(loop.id): iteration \(next)", &transition)
  }

  static func touchesOutsideWorld(_ steps: [WorkflowStep]) -> Bool {
    steps.contains { step in
      switch step.verb {
      case .message, .launch, .run, .wait, .close: return true
      case .loop(_, _, let body): return touchesOutsideWorld(body)
      case .set, .notify, .breakLoop, .continueLoop: return false
      }
    }
  }

  // MARK: - Outside-world verbs

  private mutating func enterMessage(
    _ step: WorkflowStep,
    role: String,
    content: WorkflowMessageContent,
    expect: WorkflowExpectation?,
    _ transition: inout Transition
  ) {
    let selfInitiation = transition.allowSelfInitiation
    transition.allowSelfInitiation = false
    guard let binding = run.bindings[role], let paneID = binding.paneID else {
      fail(step: step, reason: "role \(role) has no pane", &transition)
      return
    }
    let ordinal = mintOrdinal()
    run.steps[step.id]?.ordinal = ordinal
    if let expect {
      openActivation(for: step, role: role, paneID: paneID, ordinal: ordinal, expect: expect, &transition)
    }
    if selfInitiation, case .current(let pane) = binding, pane == run.configuration.initiatorPaneID {
      selfInitiate(step, content: content, ordinal: ordinal, &transition)
      return
    }
    awaitIdle(role: role, paneID: paneID, ordinal: ordinal, &transition)
  }

  mutating func awaitIdle(role: String, paneID: PaneID, ordinal: Int, _ transition: inout Transition) {
    run.phase = .waitingForRole(role: role, ordinal: ordinal)
    transition.effects.append(.awaitRole(role: role, paneID: paneID, until: .idle, timeoutMinutes: nil))
    log("step \(run.currentStepID ?? ""): waiting for \(role) to go idle", &transition)
  }

  private mutating func openActivation(
    for step: WorkflowStep,
    role: String,
    paneID: PaneID?,
    ordinal: Int,
    expect: WorkflowExpectation,
    _ transition: inout Transition
  ) {
    let token = transition.makeToken()
    run.activations[ordinal] = WorkflowActivation(
      ordinal: ordinal,
      stepID: step.id,
      role: role,
      paneID: paneID,
      delivery: expect.delivery,
      expectation: expect,
      token: token,
      iteration: run.cursor.iteration
    )
    transition.effects.append(.openActivation(ordinal: ordinal, paneID: paneID, token: token))
  }

  /// The initiating agent already holds the task in its hands: hand the
  /// rendered line back instead of typing it into the pane it called
  /// from. Everything else (instruction file, activation, watchdog) is
  /// unchanged.
  private mutating func selfInitiate(
    _ step: WorkflowStep, content: WorkflowMessageContent, ordinal: Int, _ transition: inout Transition
  ) {
    guard let injection = renderInjection(for: step, content: content, ordinal: ordinal, &transition) else {
      return
    }
    if let instruction = injection.instruction {
      transition.effects.append(
        .materializeInstruction(ordinal: ordinal, stepID: step.id, text: instruction.text))
    }
    let activation = run.activations[ordinal]
    transition.selfInitiated = WorkflowSelfInitiatedTask(
      stepID: step.id,
      ordinal: ordinal,
      line: injection.line,
      instructionPath: injection.instruction?.path,
      completionCommand: activation.map(completionCommand(for:))
    )
    log("step \(step.id): self-initiated by \(run.currentStep?.role ?? "")", &transition)
    if activation != nil {
      armWatchdog(ordinal: ordinal, &transition)
    } else {
      completeStep(step, outcome: .success, &transition)
    }
  }

  struct Injection {
    var line: String
    var instruction: (path: String, text: String)?
  }

  /// The `(role, content, expect)` a step types into a pane: a `message`,
  /// or a `run` with `in:`, which is typed as one line and never expects
  /// a delivery.
  func injectionContent(of step: WorkflowStep) -> (role: String, content: WorkflowMessageContent)? {
    switch step.verb {
    case .message(let role, let content, _):
      return (role, content)
    case .run(let command):
      guard let role = command.inRole else { return nil }
      return (role, .text(command.command))
    default:
      return nil
    }
  }

  /// Renders the line to type and, for an instruction, the file behind
  /// the pointer. A failure ends the run and returns `nil`.
  mutating func renderInjection(
    for step: WorkflowStep, content: WorkflowMessageContent, ordinal: Int, _ transition: inout Transition
  ) -> Injection? {
    let suffix = run.activations[ordinal].map { WorkflowCompletionCommand.suffix(command: completionCommand(for: $0)) }
    switch content {
    case .instruction(let template):
      guard let text = render(template, for: step, &transition) else { return nil }
      let path = WorkflowRunLayout.instructionPath(
        runDirectory: run.configuration.runDirectory, stepID: step.id, ordinal: ordinal)
      return Injection(line: "[codans] Read and follow \(path)" + (suffix ?? ""), instruction: (path, text))
    case .text(let template):
      guard let line = render(template, for: step, &transition) else { return nil }
      guard !line.contains(where: \.isNewline) else {
        fail(step: step, reason: "RENDERED_TEXT_INVALID: text renders to more than one line", &transition)
        return nil
      }
      return Injection(line: line + (suffix ?? ""), instruction: nil)
    }
  }

  mutating func armWatchdog(ordinal: Int, _ transition: inout Transition) {
    guard var activation = run.activations[ordinal] else { return }
    let deadline = activation.expectation.timeoutMinutes.map {
      transition.now.addingTimeInterval(TimeInterval($0 * 60))
    }
    activation.deadline = deadline
    run.activations[ordinal] = activation
    run.phase = .waitingForDelivery(ordinal: ordinal)
    transition.effects.append(
      .armWatchdog(ordinal: ordinal, idleGraceSeconds: run.configuration.idleGraceSeconds, deadline: deadline))
  }

  private mutating func enterLaunch(
    _ step: WorkflowStep,
    role: String,
    prompt: WorkflowTemplate,
    expect: WorkflowExpectation?,
    _ transition: inout Transition
  ) {
    transition.allowSelfInitiation = false
    guard case .launch(let profileID, _, _, let paneID)? = run.bindings[role] else {
      fail(step: step, reason: "role \(role) is not a launch role", &transition)
      return
    }
    guard paneID == nil else {
      fail(step: step, reason: "role \(role) was already launched", &transition)
      return
    }
    let ordinal = mintOrdinal()
    run.steps[step.id]?.ordinal = ordinal
    guard var rendered = render(prompt, for: step, &transition) else { return }
    var environment = launchEnvironment(role: role)
    if let expect {
      openActivation(for: step, role: role, paneID: nil, ordinal: ordinal, expect: expect, &transition)
      if let activation = run.activations[ordinal] {
        rendered += WorkflowCompletionCommand.prompt(command: completionCommand(for: activation))
        environment[CodansEnvironment.Key.workflowToken.rawValue] = activation.token
      }
    }
    emitLaunch(
      role: role, profileID: profileID, ordinal: ordinal, prompt: rendered, environment: environment, &transition)
  }

  func launchEnvironment(role: String) -> [String: String] {
    [
      CodansEnvironment.Key.workflowRun.rawValue: run.id.uuidString,
      CodansEnvironment.Key.workflowRole.rawValue: role,
    ]
  }

  mutating func emitLaunch(
    role: String,
    profileID: UUID,
    ordinal: Int,
    prompt: String,
    environment: [String: String],
    _ transition: inout Transition
  ) {
    let definition = run.definition.role(named: role) ?? WorkflowRole(name: role, source: .launch)
    let anchor = run.bindings.values.first { $0.source == .current }?.paneID ?? run.configuration.initiatorPaneID
    run.phase = .launching(ordinal: ordinal)
    transition.effects.append(
      .launch(
        WorkflowLaunchRequest(
          role: role,
          ordinal: ordinal,
          profileID: profileID,
          prompt: prompt,
          placement: definition.placement,
          direction: definition.direction,
          background: definition.background,
          anchorPaneID: anchor,
          environment: environment
        )))
    log("step \(run.currentStepID ?? ""): launching \(role)", &transition)
  }

  private mutating func enterRun(_ step: WorkflowStep, _ command: WorkflowRunCommand, _ transition: inout Transition) {
    transition.allowSelfInitiation = false
    if let role = command.inRole {
      guard let paneID = run.paneID(for: role) else {
        fail(step: step, reason: "role \(role) has no pane", &transition)
        return
      }
      let ordinal = mintOrdinal()
      run.steps[step.id]?.ordinal = ordinal
      awaitIdle(role: role, paneID: paneID, ordinal: ordinal, &transition)
      return
    }
    guard let rendered = render(command.command, for: step, &transition) else { return }
    var workingDirectory = run.configuration.source.worktreePath
    if let template = command.workingDirectory {
      guard let directory = render(template, for: step, &transition) else { return }
      workingDirectory = directory
    }
    var environment: [String: String] = [:]
    for (name, template) in command.env {
      guard let value = render(template, for: step, &transition) else { return }
      environment[name] = value
    }
    let ordinal = mintOrdinal()
    run.steps[step.id]?.ordinal = ordinal
    run.phase = .runningCommand(stepID: step.id)
    transition.effects.append(
      .runCommand(
        stepID: step.id,
        ordinal: ordinal,
        command: rendered,
        workingDirectory: workingDirectory,
        environment: environment,
        timeoutSeconds: command.timeoutMinutes * 60
      ))
    log("step \(step.id): running command", &transition)
  }

  private mutating func enterWait(
    _ step: WorkflowStep,
    role: String,
    until: WorkflowWaitCondition,
    timeoutMinutes: Int?,
    _ transition: inout Transition
  ) {
    transition.allowSelfInitiation = false
    guard let paneID = run.paneID(for: role) else {
      fail(step: step, reason: "role \(role) has no pane", &transition)
      return
    }
    let ordinal = mintOrdinal()
    run.steps[step.id]?.ordinal = ordinal
    awaitState(role: role, paneID: paneID, until: until, timeoutMinutes: timeoutMinutes, &transition)
  }

  mutating func awaitState(
    role: String,
    paneID: PaneID,
    until: WorkflowWaitCondition,
    timeoutMinutes: Int?,
    _ transition: inout Transition
  ) {
    run.phase = .waitingForState(role: role, until: until)
    transition.effects.append(.awaitRole(role: role, paneID: paneID, until: until, timeoutMinutes: timeoutMinutes))
    log("step \(run.currentStepID ?? ""): waiting for \(role) until \(until.rawValue)", &transition)
  }

  private mutating func enterClose(_ step: WorkflowStep, role: String, _ transition: inout Transition) {
    transition.allowSelfInitiation = false
    guard case .launch(let profileID, let profileName, let agent, let paneID)? = run.bindings[role] else {
      fail(step: step, reason: "role \(role) is not a launch role", &transition)
      return
    }
    guard let paneID else {
      fail(step: step, reason: "role \(role) has no pane", &transition)
      return
    }
    transition.effects.append(.closePane(paneID: paneID, role: role))
    run.bindings[role] = .launch(profileID: profileID, profileName: profileName, agent: agent, paneID: nil)
    run.roleStates[role] = "gone"
    completeStep(step, outcome: .success, &transition)
  }
}
