import Foundation

/// Event handling. Each handler first checks that the event answers the
/// wait the run is actually in; anything else is stale and ignored.
extension WorkflowMachine {
  mutating func handle(_ event: WorkflowRunEvent, _ transition: inout Transition) {
    switch event {
    case .roleIdle(let role):
      handleRoleState(role, observed: .idle, &transition)
    case .roleBlocked(let role):
      handleRoleState(role, observed: .blocked, &transition)
    case .roleExited(let role):
      handleRoleState(role, observed: .exit, &transition)
    case .roleGone(let role):
      handleRoleGone(role, &transition)
    case .waitTimedOut(let role):
      handleWaitTimedOut(role, &transition)
    case .injected(let ordinal):
      handleInjected(ordinal, &transition)
    case .injectionFailed(let ordinal, let reason):
      handleInjectionFailed(ordinal, reason: reason, &transition)
    case .launched(let ordinal, let paneID):
      handleLaunched(ordinal, paneID: paneID, &transition)
    case .launchFailed(let ordinal, let reason):
      handleLaunchFailed(ordinal, reason: reason, &transition)
    case .commandFinished(let stepID, let exitCode, let stdout, let stdoutPath, let timedOut, let spawnFailure):
      handleCommandFinished(
        stepID, exitCode: exitCode, stdout: stdout, stdoutPath: stdoutPath, timedOut: timedOut,
        spawnFailure: spawnFailure, &transition)
    case .deliveryPersisted(let ordinal, let path, let latestPath):
      handleDeliveryPersisted(ordinal, path: path, latestPath: latestPath, &transition)
    case .deliveryPersistFailed(let ordinal, let reason):
      handleDeliveryPersistFailed(ordinal, reason: reason, &transition)
    case .watchdog(let ordinal, let signal):
      handleWatchdog(ordinal, signal, &transition)
    case .user(let action, let verdict):
      handleUser(action, verdict: verdict, &transition)
    }
  }

  // MARK: - Role state

  /// Whether `role` is the one the current phase waits on.
  private func isWaiting(on role: String) -> Bool {
    switch run.phase {
    case .waitingForRole(let waited, _), .waitingForState(let waited, _):
      return waited == role
    case .waitingForDelivery:
      return run.currentStep?.role == role
    case .idle, .injecting, .launching, .runningCommand, .finished:
      return false
    }
  }

  private mutating func handleRoleState(
    _ role: String, observed: WorkflowWaitCondition, _ transition: inout Transition
  ) {
    run.roleStates[role] = observed == .exit ? "finished" : observed.rawValue
    guard run.status == .running, isWaiting(on: role), let step = run.currentStep else { return }
    switch run.phase {
    case .waitingForRole(_, let ordinal):
      switch observed {
      case .idle: inject(step, ordinal: ordinal, &transition)
      case .blocked: raiseRoleBlocked(role, &transition)
      case .exit: raiseRoleGone(role, &transition)
      }
    case .waitingForState(_, let until):
      if observed == until {
        complete(step, outcome: .success, &transition)
      } else if observed == .blocked {
        raiseRoleBlocked(role, &transition)
      } else if observed == .exit {
        raiseRoleGone(role, &transition)
      }
    case .waitingForDelivery:
      if observed == .blocked {
        raiseRoleBlocked(role, &transition)
      } else if observed == .exit {
        raiseRoleGone(role, &transition)
      }
    case .idle, .injecting, .launching, .runningCommand, .finished:
      break
    }
  }

  private mutating func handleRoleGone(_ role: String, _ transition: inout Transition) {
    run.roleStates[role] = "gone"
    guard run.status == .running, isWaiting(on: role) else { return }
    raiseRoleGone(role, &transition)
  }

  private mutating func handleWaitTimedOut(_ role: String, _ transition: inout Transition) {
    guard run.status == .running, isWaiting(on: role) else { return }
    switch run.phase {
    case .waitingForRole, .waitingForState:
      stopWaiting(&transition)
      raiseAttention(
        attention(
          .waitTimeout, message: "\(role) did not reach the awaited state in time",
          actions: [.keepWaiting, .skip, .cancel]),
        &transition)
    case .idle, .injecting, .launching, .waitingForDelivery, .runningCommand, .finished:
      break
    }
  }

  /// Releases whatever the current phase is waiting on, so an attention
  /// never leaves a live wait behind; `keepWaiting` re-issues it.
  mutating func stopWaiting(_ transition: inout Transition) {
    switch run.phase {
    case .waitingForRole(let role, _), .waitingForState(let role, _):
      transition.effects.append(.cancelRoleWait(role: role))
    case .waitingForDelivery(let ordinal):
      transition.effects.append(.disarmWatchdog(ordinal: ordinal))
    case .idle, .injecting, .launching, .runningCommand, .finished:
      break
    }
  }

  private mutating func raiseRoleBlocked(_ role: String, _ transition: inout Transition) {
    stopWaiting(&transition)
    raiseAttention(
      attention(
        .roleBlocked, message: "\(role) is waiting on a prompt in its pane",
        actions: [.focusPane, .keepWaiting, .skip, .cancel]),
      &transition)
  }

  private mutating func raiseRoleGone(_ role: String, _ transition: inout Transition) {
    stopWaiting(&transition)
    var actions: [WorkflowUserAction] = [.skip, .cancel]
    if run.bindings[role]?.isLaunch == true {
      actions.insert(.relaunch, at: 0)
    }
    raiseAttention(
      attention(.roleGone, message: "the pane for \(role) is gone", actions: actions), &transition)
  }

  // MARK: - Injection

  /// The role is idle: type the pending reminder if there is one, else
  /// render the step's own line (materializing an instruction first).
  private mutating func inject(_ step: WorkflowStep, ordinal: Int, _ transition: inout Transition) {
    guard let target = injectionContent(of: step), let paneID = run.paneID(for: target.role) else {
      fail(step: step, reason: "step \(step.id) has nothing to type", &transition)
      return
    }
    let line: String
    if let pending = run.activations[ordinal]?.pendingLine {
      run.activations[ordinal]?.pendingLine = nil
      line = pending
    } else {
      guard let injection = renderInjection(for: step, content: target.content, ordinal: ordinal, &transition)
      else { return }
      if let instruction = injection.instruction {
        transition.effects.append(
          .materializeInstruction(ordinal: ordinal, stepID: step.id, text: instruction.text))
      }
      line = injection.line
    }
    run.phase = .injecting(ordinal: ordinal)
    transition.effects.append(.inject(paneID: paneID, ordinal: ordinal, line: line))
    log("step \(step.id): injecting into \(target.role)", &transition)
  }

  private mutating func handleInjected(_ ordinal: Int, _ transition: inout Transition) {
    guard run.status == .running, run.phase == .injecting(ordinal: ordinal), let step = run.currentStep else {
      return
    }
    if run.activations[ordinal]?.state == .waiting {
      armWatchdog(ordinal: ordinal, &transition)
      log("step \(step.id): waiting for delivery #\(ordinal)", &transition)
    } else {
      complete(step, outcome: .success, &transition)
    }
  }

  private mutating func handleInjectionFailed(_ ordinal: Int, reason: String, _ transition: inout Transition) {
    guard run.status == .running, run.phase == .injecting(ordinal: ordinal) else { return }
    raiseAttention(
      attention(
        .injectionFailed, message: "could not type into the pane: \(reason)", actions: [.retry, .skip, .cancel]),
      &transition)
  }

  // MARK: - Launch

  private mutating func handleLaunched(_ ordinal: Int, paneID: PaneID, _ transition: inout Transition) {
    // The launched role is the current step's: either the `launch` step
    // itself or a step that relaunched the role it addresses.
    guard run.status == .running, run.phase == .launching(ordinal: ordinal), let step = run.currentStep,
      let role = step.role,
      case .launch(let profileID, let profileName, let agent, _)? = run.bindings[role]
    else { return }
    run.bindings[role] = .launch(profileID: profileID, profileName: profileName, agent: agent, paneID: paneID)
    log("step \(step.id): \(role) launched in pane \(paneID)", &transition)
    guard case .launch = step.verb else {
      // A relaunch in the middle of another step: start that step over.
      reenterCurrentStep(&transition)
      return
    }
    if var activation = run.activations[ordinal], activation.state == .waiting {
      activation.paneID = paneID
      run.activations[ordinal] = activation
      transition.effects.append(.openActivation(ordinal: ordinal, paneID: paneID, token: activation.token))
      armWatchdog(ordinal: ordinal, &transition)
    } else {
      complete(step, outcome: .success, &transition)
    }
  }

  private mutating func handleLaunchFailed(_ ordinal: Int, reason: String, _ transition: inout Transition) {
    guard run.status == .running, run.phase == .launching(ordinal: ordinal) else { return }
    raiseAttention(
      attention(.launchFailed, message: "launch failed: \(reason)", actions: [.relaunch, .cancel]), &transition)
  }

  // MARK: - Commands

  private mutating func handleCommandFinished(
    _ stepID: String,
    exitCode: Int?,
    stdout: String,
    stdoutPath: String,
    timedOut: Bool,
    spawnFailure: String?,
    _ transition: inout Transition
  ) {
    guard run.status == .running, run.phase == .runningCommand(stepID: stepID), let step = run.currentStep,
      case .run(let command) = step.verb
    else { return }
    run.stepOutputs[stepID] = .object([
      "exit-code": exitCode.map(WorkflowValue.int) ?? .null,
      "stdout": .string(Self.truncated(stdout, toBytes: Self.maximumContextStdoutBytes)),
      "stdout-path": .string(stdoutPath),
    ])
    let succeeded = exitCode == 0 && !timedOut && spawnFailure == nil
    if succeeded {
      complete(step, outcome: .success, &transition)
      return
    }
    let reason: String
    if let spawnFailure {
      reason = "could not start: \(spawnFailure)"
    } else if timedOut {
      reason = "timed out after \(command.timeoutMinutes) minute(s)"
    } else {
      reason = "exit code \(exitCode.map(String.init) ?? "unknown")"
    }
    if command.continueOnError {
      log("step \(stepID): \(reason) (continue-on-error)", &transition)
      complete(step, outcome: .failure, &transition)
      return
    }
    raiseAttention(
      attention(.commandFailed, message: "command failed: \(reason)", actions: [.retry, .skip, .cancel]),
      &transition)
  }

  /// Cuts on a character boundary so the kept prefix is still valid text.
  static func truncated(_ text: String, toBytes limit: Int) -> String {
    guard text.utf8.count > limit else { return text }
    var kept = ""
    var bytes = 0
    for character in text {
      bytes += character.utf8.count
      if bytes > limit { break }
      kept.append(character)
    }
    return kept
  }

  // MARK: - Watchdog

  private mutating func handleWatchdog(
    _ ordinal: Int,
    _ signal: WorkflowWatchdogSignal,
    _ transition: inout Transition
  ) {
    guard run.status == .running, run.phase == .waitingForDelivery(ordinal: ordinal),
      var activation = run.activations[ordinal], activation.state == .waiting, let paneID = activation.paneID
    else { return }
    switch signal {
    case .idleGraceElapsed:
      if activation.nudged {
        stopWaiting(&transition)
        raiseAttention(
          attention(
            .noDeliveryAfterIdle, message: "\(activation.role) went idle without delivering \(activation.delivery)",
            actions: [.keepWaiting, .askAgain, .skip, .cancel]),
          &transition)
        return
      }
      activation.nudged = true
      run.activations[ordinal] = activation
      let line = WorkflowCompletionCommand.nudgeLine(command: completionCommand(for: activation))
      transition.effects.append(.inject(paneID: paneID, ordinal: ordinal, line: line))
      transition.effects.append(
        .armWatchdog(
          ordinal: ordinal, idleGraceSeconds: run.configuration.idleGraceSeconds, deadline: activation.deadline))
      log("step \(activation.stepID): nudged \(activation.role)", &transition)
    case .deadlineReached:
      switch activation.expectation.onTimeout {
      case .attention:
        stopWaiting(&transition)
        raiseAttention(
          attention(
            .deliveryTimeout, message: "\(activation.role) did not deliver \(activation.delivery) in time",
            actions: [.keepWaiting, .skip, .cancel]),
          &transition)
      case .skip:
        log("step \(activation.stepID): delivery timed out (on-timeout: skip)", &transition)
        performSkip(&transition)
      case .cancel:
        log("step \(activation.stepID): delivery timed out (on-timeout: cancel)", &transition)
        performCancel(&transition)
      }
    }
  }

  // MARK: - Delivery persistence

  private mutating func handleDeliveryPersisted(
    _ ordinal: Int, path: String, latestPath: String, _ transition: inout Transition
  ) {
    guard var activation = run.activations[ordinal], activation.state == .persisting, let step = run.currentStep,
      ordinal == run.currentOrdinal
    else { return }
    let provisional = !activation.issues.isEmpty
    run.deliveries[activation.delivery] = WorkflowDeliveryRecord(
      name: activation.delivery,
      ordinal: ordinal,
      path: path,
      latestPath: latestPath,
      verdict: activation.verdict,
      isProvisional: provisional,
      deliveredAt: transition.now
    )
    transition.effects.append(.disarmWatchdog(ordinal: ordinal))
    if provisional {
      activation.state = .provisional
      run.activations[ordinal] = activation
      raiseAttention(provisionalAttention(for: activation), &transition)
      return
    }
    activation.state = .delivered
    run.activations[ordinal] = activation
    run.status = .running
    log("delivery \(activation.delivery)#\(ordinal): recorded at \(path)", &transition)
    complete(step, outcome: .success, &transition)
  }

  private func provisionalAttention(for activation: WorkflowActivation) -> WorkflowAttention {
    var actions: [WorkflowUserAction] = [.accept]
    if let verdicts = activation.expectation.verdicts, !verdicts.isEmpty, activation.verdict == nil {
      actions.append(.acceptWithVerdict)
    }
    actions.append(contentsOf: [.askAgain, .skip, .cancel])
    return attention(
      .provisionalDelivery,
      message:
        "\(activation.delivery) from \(activation.role) needs review: \(activation.issues.joined(separator: "; "))",
      actions: actions,
      issues: activation.issues
    )
  }

  private mutating func handleDeliveryPersistFailed(_ ordinal: Int, reason: String, _ transition: inout Transition) {
    guard var activation = run.activations[ordinal], activation.state == .persisting else { return }
    activation.state = .waiting
    activation.issues = []
    activation.verdict = nil
    run.activations[ordinal] = activation
    log("delivery \(activation.delivery)#\(ordinal): could not be written — \(reason)", &transition)
  }
}
