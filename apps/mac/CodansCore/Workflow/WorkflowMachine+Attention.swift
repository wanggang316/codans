import Foundation

/// User actions. `cancel` is accepted whenever the run is alive; every
/// other action must be one the current attention offered, so the
/// action table the machine published is also the one it enforces.
extension WorkflowMachine {
  mutating func handleUser(_ action: WorkflowUserAction, verdict: String?, _ transition: inout Transition) {
    log("user: \(action.rawValue)\(verdict.map { " \($0)" } ?? "")", &transition)
    if action == .cancel {
      performCancel(&transition)
      return
    }
    guard let attention = run.status.attention, attention.actions.contains(action) else {
      log("user: \(action.rawValue) is not available now; ignored", &transition)
      return
    }
    switch action {
    case .accept:
      performAccept(verdict: nil, &transition)
    case .acceptWithVerdict:
      performAccept(verdict: verdict, &transition)
    case .askAgain:
      performAskAgain(&transition)
    case .keepWaiting:
      performKeepWaiting(reason: attention.reason, &transition)
    case .skip:
      performSkip(&transition)
    case .relaunch:
      performRelaunch(&transition)
    case .retry:
      performRetry(reason: attention.reason, &transition)
    case .focusPane, .cancel:
      // Informational: the engine focuses the pane; the run stays put.
      break
    }
  }

  // MARK: - Accept

  private mutating func performAccept(verdict: String?, _ transition: inout Transition) {
    guard let ordinal = run.currentOrdinal, var activation = run.activations[ordinal],
      activation.state == .provisional, let step = run.currentStep
    else { return }
    if let verdict {
      guard let allowed = activation.expectation.verdicts, allowed.contains(verdict) else {
        log("user: verdict \(verdict) is not one of the declared verdicts; ignored", &transition)
        return
      }
      activation.verdict = verdict
      run.deliveries[activation.delivery]?.verdict = verdict
    }
    activation.state = .delivered
    run.activations[ordinal] = activation
    run.deliveries[activation.delivery]?.isProvisional = false
    run.status = .running
    transition.effects.append(.revokeActivation(ordinal: ordinal))
    log("delivery \(activation.delivery)#\(ordinal): accepted by user", &transition)
    complete(step, outcome: .success, &transition)
  }

  // MARK: - Ask again

  /// Re-types what was missing plus the same completion command, once the
  /// role is idle again. The token stays valid.
  private mutating func performAskAgain(_ transition: inout Transition) {
    guard let ordinal = run.currentOrdinal, var activation = run.activations[ordinal],
      activation.state == .provisional || activation.state == .waiting, let paneID = activation.paneID
    else { return }
    activation.pendingLine = WorkflowCompletionCommand.askAgainLine(
      issues: activation.issues, command: completionCommand(for: activation))
    activation.state = .waiting
    activation.nudged = false
    run.activations[ordinal] = activation
    run.status = .running
    awaitIdle(role: activation.role, paneID: paneID, ordinal: ordinal, &transition)
  }

  // MARK: - Keep waiting

  private mutating func performKeepWaiting(reason: WorkflowAttention.Reason, _ transition: inout Transition) {
    run.status = .running
    switch run.phase {
    case .waitingForRole(let role, let ordinal):
      guard let paneID = run.paneID(for: role) else { return }
      awaitIdle(role: role, paneID: paneID, ordinal: ordinal, &transition)
    case .waitingForState(let role, let until):
      guard let paneID = run.paneID(for: role), let step = run.currentStep,
        case .wait(_, _, let timeoutMinutes) = step.verb
      else { return }
      awaitState(role: role, paneID: paneID, until: until, timeoutMinutes: timeoutMinutes, &transition)
    case .waitingForDelivery(let ordinal):
      rearmWatchdog(ordinal: ordinal, extendingDeadline: reason == .deliveryTimeout, &transition)
    case .idle, .injecting, .launching, .runningCommand, .finished:
      break
    }
  }

  /// After a timeout the user asked for another full period; after an
  /// idle-grace attention the original deadline still stands.
  private mutating func rearmWatchdog(ordinal: Int, extendingDeadline: Bool, _ transition: inout Transition) {
    guard var activation = run.activations[ordinal] else { return }
    if extendingDeadline, let minutes = activation.expectation.timeoutMinutes {
      activation.deadline = transition.now.addingTimeInterval(TimeInterval(minutes * 60))
    }
    activation.nudged = false
    run.activations[ordinal] = activation
    transition.effects.append(
      .armWatchdog(
        ordinal: ordinal, idleGraceSeconds: run.configuration.idleGraceSeconds, deadline: activation.deadline))
  }

  // MARK: - Skip

  /// Skips the current step. When a later step needs the delivery this
  /// one would have produced, the run ends as `skipped(step:dependent:)`
  /// instead of failing later on a missing reference.
  mutating func performSkip(_ transition: inout Transition) {
    guard let step = run.currentStep else { return }
    stopWaiting(&transition)
    closeActivation(as: .skipped, &transition)
    if let expect = step.expectation, let dependent = skipConsequence(forDelivery: expect.delivery) {
      finishStep(step.id, outcome: .skipped, &transition)
      finish(.skipped(step: step.id, dependent: dependent), &transition)
      return
    }
    run.status = .running
    complete(step, outcome: .skipped, &transition)
  }

  // MARK: - Cancel

  /// Ends the run without touching any pane: the agents keep whatever
  /// they were doing, only the run stops listening.
  mutating func performCancel(_ transition: inout Transition) {
    stopWaiting(&transition)
    closeActivation(as: .revoked, &transition)
    if let step = run.currentStep, run.steps[step.id]?.outcome == nil {
      finishStep(step.id, outcome: .failure, &transition)
    }
    finish(.cancelled, &transition)
  }

  /// Retires the current activation (if one is open) and its token.
  private mutating func closeActivation(as state: WorkflowActivationState, _ transition: inout Transition) {
    guard let ordinal = run.currentOrdinal, var activation = run.activations[ordinal] else { return }
    switch activation.state {
    case .waiting, .persisting, .provisional:
      activation.state = state
      activation.pendingLine = nil
      run.activations[ordinal] = activation
      transition.effects.append(.revokeActivation(ordinal: ordinal))
    case .delivered, .skipped, .revoked:
      break
    }
  }

  // MARK: - Relaunch

  /// Starts the current step's launch role again. On the `launch` step
  /// itself that is simply re-entering the step; elsewhere the role's
  /// original prompt is replayed and the current step restarts once the
  /// new pane reports in.
  private mutating func performRelaunch(_ transition: inout Transition) {
    guard let step = run.currentStep, let role = step.role,
      case .launch(let profileID, let profileName, let agent, _)? = run.bindings[role]
    else { return }
    closeActivation(as: .revoked, &transition)
    run.bindings[role] = .launch(profileID: profileID, profileName: profileName, agent: agent, paneID: nil)
    if case .launch = step.verb {
      reenterCurrentStep(&transition)
      return
    }
    guard let launchStep = run.definition.flattenedSteps.first(where: { $0.role == role && $0.isLaunch }),
      case .launch(_, let prompt, _) = launchStep.verb
    else {
      fail(step: step, reason: "role \(role) has no launch step to replay", &transition)
      return
    }
    run.status = .running
    let ordinal = mintOrdinal()
    guard let rendered = render(prompt, for: step, &transition) else { return }
    emitLaunch(
      role: role, profileID: profileID, ordinal: ordinal, prompt: rendered,
      environment: launchEnvironment(role: role), &transition)
  }

  // MARK: - Retry

  private mutating func performRetry(reason: WorkflowAttention.Reason, _ transition: inout Transition) {
    switch reason {
    case .commandFailed:
      reenterCurrentStep(&transition)
    case .injectionFailed:
      guard case .injecting(let ordinal) = run.phase, let step = run.currentStep,
        let target = injectionContent(of: step), let paneID = run.paneID(for: target.role)
      else { return }
      run.status = .running
      awaitIdle(role: target.role, paneID: paneID, ordinal: ordinal, &transition)
    case .provisionalDelivery, .roleBlocked, .roleGone, .deliveryTimeout, .noDeliveryAfterIdle, .launchFailed,
      .waitTimeout:
      break
    }
  }
}

extension WorkflowStep {
  var isLaunch: Bool {
    if case .launch = verb { return true }
    return false
  }
}
