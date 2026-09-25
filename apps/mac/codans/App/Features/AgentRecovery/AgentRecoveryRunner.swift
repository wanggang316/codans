import CodansCore
import Foundation
import OSLog

private let recoveryLogger = Logger(subsystem: "com.gumpw.codans.agentrecovery", category: "runner")

/// Recovery is separate from the wall-clock command queue: every action must
/// still belong to the same live Agent, policy and failure when it is delivered.
@MainActor
final class AgentRecoveryRunner {
  struct Target: Equatable {
    let paneID: PaneID
    let generation: UUID
    let kind: AgentKind
    let sessionID: String?
    let directory: URL
    let isError: Bool
    var isBusy = false
    var processGroupID: Int32?
    var processStartedAt: Date?
  }

  private struct Attempt {
    let generation: UUID
    var count = 0
    var dueAt: Date
    var wasError = true
  }

  typealias Validation = @MainActor (_ requireError: Bool) -> Bool
  typealias Delivery =
    @MainActor (Target, AgentRecoveryPolicy, Int, @escaping Validation) async -> Void

  private let policy: @MainActor () -> AgentRecoveryPolicy
  private let targets: @MainActor () -> [Target]
  private let deliver: Delivery
  private let now: () -> Date
  private var attempts: [PaneID: Attempt] = [:]
  private var active: [PaneID: Task<Void, Never>] = [:]
  private var activeIDs: [PaneID: UUID] = [:]
  private var lastPolicy: AgentRecoveryPolicy?
  private var policyGeneration = UUID()
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
    policyGeneration = UUID()
    attempts.removeAll()
    for task in active.values { task.cancel() }
  }

  /// Attempts remain spent across working/error oscillations. Only explicit
  /// user input, rebinding or a policy change grants a fresh budget; a transient
  /// idle frame cannot turn repeated failed requests into an unbounded loop.
  func drain() {
    let currentPolicy = policy()
    if currentPolicy != lastPolicy {
      policyGeneration = UUID()
      lastPolicy = currentPolicy
      attempts.removeAll()
      for task in active.values { task.cancel() }
    }
    guard currentPolicy.isEnabled, currentPolicy.isValid else { return }
    let currentTargets = targets()
    let liveIDs = Set(currentTargets.map(\.paneID))
    attempts = attempts.filter { liveIDs.contains($0.key) }
    for (id, task) in active where !liveIDs.contains(id) { task.cancel() }
    let instant = now()
    for target in currentTargets {
      var attempt = attempts[target.paneID]
      if attempt?.generation != target.generation {
        active[target.paneID]?.cancel()
        attempt = Attempt(
          generation: target.generation,
          dueAt: instant.addingTimeInterval(TimeInterval(currentPolicy.delaySeconds))
        )
      }
      guard var attempt else { continue }
      if !target.isError {
        attempt.wasError = false
        attempt.dueAt = instant.addingTimeInterval(TimeInterval(currentPolicy.delaySeconds))
        attempts[target.paneID] = attempt
        // Pasting can turn an error banner into an idle composer before
        // Return. Only busy/blocked state should interrupt that prompt gap.
        if target.isBusy || currentPolicy.action == .script {
          active[target.paneID]?.cancel()
        }
        continue
      }
      if !attempt.wasError {
        attempt.wasError = true
        attempt.dueAt = instant.addingTimeInterval(TimeInterval(currentPolicy.delaySeconds))
      }
      attempts[target.paneID] = attempt
      guard active[target.paneID] == nil, attempt.count < currentPolicy.maxAttempts,
        instant >= attempt.dueAt
      else { continue }
      attempt.count += 1
      attempt.dueAt = instant.addingTimeInterval(TimeInterval(currentPolicy.delaySeconds))
      attempts[target.paneID] = attempt
      launch(target, policy: currentPolicy, count: attempt.count)
    }
  }

  private func launch(_ target: Target, policy: AgentRecoveryPolicy, count: Int) {
    recoveryLogger.info("Recovery attempt \(count) for pane \(target.paneID.raw.uuidString, privacy: .public)")
    let revision = policyGeneration
    let operationID = UUID()
    activeIDs[target.paneID] = operationID
    let validate: Validation = { [weak self] requireError in
      guard let self, !Task.isCancelled, self.policyGeneration == revision,
        self.policy() == policy, policy.isEnabled, policy.isValid
      else { return false }
      return self.targets().contains { candidate in
        candidate.paneID == target.paneID && candidate.generation == target.generation
          && candidate.kind == target.kind && candidate.sessionID == target.sessionID
          && candidate.directory == target.directory
          && candidate.processGroupID == target.processGroupID
          && candidate.processStartedAt == target.processStartedAt
          && (requireError ? candidate.isError : !candidate.isBusy)
      }
    }
    active[target.paneID] = Task { @MainActor [weak self] in
      guard let self else { return }
      if validate(true) { await self.deliver(target, policy, count, validate) }
      guard self.activeIDs[target.paneID] == operationID else { return }
      self.active.removeValue(forKey: target.paneID)
      self.activeIDs.removeValue(forKey: target.paneID)
      // Measure the delay after completion too, so a slow script cannot cause
      // the next attempt to launch immediately on the following tick.
      if self.attempts[target.paneID]?.generation == target.generation {
        self.attempts[target.paneID]?.dueAt = self.now().addingTimeInterval(
          TimeInterval(policy.delaySeconds))
      }
    }
  }
}

extension AgentRecoveryRunner {
  static func runScript(
    target: Target,
    policy: AgentRecoveryPolicy,
    attempt: Int,
    runner: any CommandRunner,
    validate: Validation
  ) async {
    guard validate(true) else { return }
    var environment = ProcessInfo.processInfo.environment
    environment["CODANS_PANE_ID"] = target.paneID.raw.uuidString
    environment["CODANS_AGENT_KIND"] = target.kind.rawValue
    environment["CODANS_AGENT_SESSION_ID"] = target.sessionID ?? ""
    environment["CODANS_RECOVERY_ATTEMPT"] = String(attempt)
    let outcome = await runner.run(
      executable: URL(fileURLWithPath: "/bin/zsh"),
      arguments: ["-lc", policy.script],
      env: environment,
      cwd: target.directory,
      timeout: .seconds(30),
      maxOutputBytes: 65_536
    )
    switch outcome {
    case .exited(let code, _, _, _):
      recoveryLogger.info("Recovery script attempt \(attempt) exited with code \(code)")
    case .timedOut:
      recoveryLogger.error("Recovery script attempt \(attempt) timed out")
    case .spawnFailed:
      recoveryLogger.error("Recovery script attempt \(attempt) could not start")
    }
  }
}
