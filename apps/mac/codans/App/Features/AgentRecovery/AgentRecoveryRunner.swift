import CodansCore
import Foundation
import OSLog

private let recoveryLogger = Logger(subsystem: "com.gumpw.codans.agentrecovery", category: "runner")

/// Budgets belong to an instance/input scope; tickets belong to one error occurrence.
@MainActor
final class AgentRecoveryRunner {
  struct Scope: Equatable {
    let instanceID: AgentInstanceID
    let externalInputRevision: UInt64
  }

  struct Target: Equatable {
    let binding: AgentBinding
    let externalInputRevision: UInt64
    let directory: URL
    let observation: AgentObservation?
    var identityIsValid = true
    var isSuppressed = false
    var hasResidualDraft = false

    var paneID: PaneID { binding.paneID }
    var scope: Scope { Scope(instanceID: binding.instanceID, externalInputRevision: externalInputRevision) }
    var failure: AgentFailure? {
      guard let observation, observation.instanceID == binding.instanceID,
        case .error(let failure) = observation.state
      else { return nil }
      return failure
    }
  }

  struct Ticket: Equatable {
    let binding: AgentBinding
    let scope: Scope
    let errorStateRevision: UInt64
    let policyRevision: UUID
  }

  private struct Attempt {
    let scope: Scope
    var count = 0
    var dueAt: Date
    var ticket: Ticket?
  }

  enum ValidationStage { case beforeWrite, beforeSubmit }
  typealias Validation = @MainActor (ValidationStage) -> Bool
  typealias StartAttempt = @MainActor () -> Bool
  typealias Delivery =
    @MainActor (
      Target, AgentRecoveryPolicy, Int, @escaping Validation, @escaping StartAttempt
    ) async -> Void

  private let policy: @MainActor () -> AgentRecoveryPolicy
  private let targets: @MainActor () -> [Target]
  private let deliver: Delivery
  private let now: () -> Date
  private var attempts: [PaneID: Attempt] = [:]
  private var active: [PaneID: Task<Void, Never>] = [:]
  private var activeIDs: [PaneID: UUID] = [:]
  private var activeTickets: [PaneID: Ticket] = [:]
  private var lastPolicy: AgentRecoveryPolicy?
  private var policyRevision = UUID()
  private var tickTask: Task<Void, Never>?

  init(
    policy: @escaping @MainActor () -> AgentRecoveryPolicy,
    targets: @escaping @MainActor () -> [Target],
    deliver: @escaping Delivery,
    now: @escaping () -> Date = Date.init
  ) {
    self.policy = policy
    self.targets = targets
    self.deliver = deliver
    self.now = now
  }

  deinit {
    tickTask?.cancel()
    for task in active.values { task.cancel() }
  }

  func start() {
    guard tickTask == nil else { return }
    tickTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, let self else { return }
        self.drain()
      }
    }
  }

  func stop() {
    tickTask?.cancel()
    tickTask = nil
    policyRevision = UUID()
    for task in active.values { task.cancel() }
  }

  func invalidate(_ paneID: PaneID) { active[paneID]?.cancel() }

  func drain() {
    let currentPolicy = policy()
    if currentPolicy != lastPolicy {
      policyRevision = UUID()
      lastPolicy = currentPolicy
      for id in Array(attempts.keys) { attempts[id]?.ticket = nil }
      for task in active.values { task.cancel() }
    }
    let currentTargets = targets()
    let liveIDs = Set(currentTargets.map(\.paneID))
    attempts = attempts.filter { liveIDs.contains($0.key) }
    for (id, task) in active where !liveIDs.contains(id) { task.cancel() }
    guard currentPolicy.isEnabled, currentPolicy.isValid else { return }
    for target in currentTargets { advance(target, policy: currentPolicy) }
  }

  private func advance(_ target: Target, policy: AgentRecoveryPolicy) {
    let instant = now()
    var attempt =
      attempts[target.paneID]
      ?? Attempt(scope: target.scope, dueAt: instant)
    if attempt.scope != target.scope {
      active[target.paneID]?.cancel()
      attempt = Attempt(scope: target.scope, dueAt: instant)
    }
    if let activeTicket = activeTickets[target.paneID],
      !matches(
        target, ticket: activeTicket, policy: policy,
        stage: policy.action == .prompt ? .beforeSubmit : .beforeWrite)
    {
      active[target.paneID]?.cancel()
    }
    guard canStart(target, policy: policy), let observation = target.observation,
      let failure = target.failure
    else {
      attempt.ticket = nil
      attempts[target.paneID] = attempt
      return
    }
    let ticket = Ticket(
      binding: target.binding, scope: target.scope,
      errorStateRevision: observation.stateRevision, policyRevision: policyRevision)
    if attempt.ticket != ticket {
      attempt.ticket = ticket
      attempt.dueAt = instant.addingTimeInterval(policy.delay(for: failure))
    }
    attempts[target.paneID] = attempt
    guard active[target.paneID] == nil, attempt.count < policy.maxAttempts,
      instant >= attempt.dueAt
    else { return }
    launch(target, ticket: ticket, policy: policy, nextAttempt: attempt.count + 1)
  }

  private func canStart(_ target: Target, policy: AgentRecoveryPolicy) -> Bool {
    guard target.identityIsValid, !target.isSuppressed, !target.hasResidualDraft,
      let observation = target.observation,
      now().timeIntervalSince(observation.observedAt) <= 2,
      let failure = target.failure, policy.allows(failure)
    else { return false }
    return policy.action == .script || observation.inputAvailability == .prompt(.empty)
  }

  private func matches(
    _ target: Target, ticket: Ticket, policy: AgentRecoveryPolicy, stage: ValidationStage
  ) -> Bool {
    guard target.binding == ticket.binding, target.scope == ticket.scope,
      target.identityIsValid, !target.isSuppressed, !target.hasResidualDraft,
      let observation = target.observation, observation.instanceID == ticket.binding.instanceID,
      now().timeIntervalSince(observation.observedAt) <= 2
    else { return false }
    switch stage {
    case .beforeWrite:
      return observation.stateRevision == ticket.errorStateRevision && canStart(target, policy: policy)
    case .beforeSubmit:
      guard case .prompt(let content) = observation.inputAvailability, content != .unknown else { return false }
      switch observation.state {
      case .idle: return true
      case .error: return observation.stateRevision == ticket.errorStateRevision
      case .unknown, .working, .blocked: return false
      }
    }
  }

  private func launch(_ target: Target, ticket: Ticket, policy: AgentRecoveryPolicy, nextAttempt: Int) {
    let operationID = UUID()
    activeIDs[target.paneID] = operationID
    activeTickets[target.paneID] = ticket
    let validate: Validation = { [weak self] stage in
      guard let self, !Task.isCancelled, self.policyRevision == ticket.policyRevision,
        self.policy() == policy, policy.isEnabled, policy.isValid
      else { return false }
      return self.targets().contains {
        $0.paneID == target.paneID && self.matches($0, ticket: ticket, policy: policy, stage: stage)
      }
    }
    var started = false
    let begin: StartAttempt = { [weak self] in
      guard let self, !started, validate(.beforeWrite),
        var attempt = self.attempts[target.paneID], attempt.scope == ticket.scope,
        attempt.count < policy.maxAttempts
      else { return false }
      started = true
      attempt.count += 1
      self.attempts[target.paneID] = attempt
      recoveryLogger.info(
        "Recovery attempt \(attempt.count) for pane \(target.paneID.raw.uuidString, privacy: .public)")
      return true
    }
    active[target.paneID] = Task { @MainActor [weak self] in
      guard let self else { return }
      if validate(.beforeWrite) { await self.deliver(target, policy, nextAttempt, validate, begin) }
      guard self.activeIDs[target.paneID] == operationID else { return }
      self.active.removeValue(forKey: target.paneID)
      self.activeIDs.removeValue(forKey: target.paneID)
      self.activeTickets.removeValue(forKey: target.paneID)
      // Cancellation may finish after advance has installed a newer occurrence
      // or policy deadline in the same scope. Only this ticket owns its cooldown.
      if self.policyRevision == ticket.policyRevision,
        self.attempts[target.paneID]?.ticket == ticket
      {
        self.attempts[target.paneID]?.dueAt = self.now().addingTimeInterval(
          target.failure.map(policy.delay(for:)) ?? TimeInterval(policy.delaySeconds))
      }
    }
  }
}

extension AgentRecoveryRunner {
  static func runScript(
    target: Target, policy: AgentRecoveryPolicy, attempt: Int,
    runner: any CommandRunner, validate: Validation, begin: StartAttempt
  ) async {
    guard validate(.beforeWrite), begin() else { return }
    var environment = ProcessInfo.processInfo.environment
    environment["CODANS_PANE_ID"] = target.paneID.raw.uuidString
    environment["CODANS_AGENT_KIND"] = target.binding.kind.rawValue
    environment["CODANS_AGENT_SESSION_ID"] = target.binding.sessionID ?? ""
    environment["CODANS_AGENT_INSTANCE_ID"] = target.binding.instanceID.rawValue.uuidString
    environment["CODANS_ERROR_STATE_REVISION"] = target.observation.map { String($0.stateRevision) } ?? ""
    environment["CODANS_RECOVERY_ATTEMPT"] = String(attempt)
    let outcome = await runner.run(
      executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", policy.script],
      env: environment, cwd: target.directory, timeout: .seconds(30), maxOutputBytes: 65_536)
    switch outcome {
    case .exited(let code, _, _, _): recoveryLogger.info("Recovery script attempt \(attempt) exited with code \(code)")
    case .timedOut: recoveryLogger.error("Recovery script attempt \(attempt) timed out")
    case .spawnFailed: recoveryLogger.error("Recovery script attempt \(attempt) could not start")
    }
  }
}
