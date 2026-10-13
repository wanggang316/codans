import CodansCore
import Foundation

/// Effect interpretation. Effects that finish at once (typing a line,
/// registry edits) answer inline; effects that wait (role polling,
/// watchdogs, launches, commands) spawn a task on the session and report
/// back through `apply`, so the run's queue never blocks on the outside
/// world. File I/O runs detached and is awaited, which keeps the queue's
/// ordering guarantee for instruction files, deliveries and records.
extension WorkflowEngine {
  func perform(_ effect: WorkflowEffect, on session: WorkflowRunSession) async {
    switch effect {
    case .awaitRole(let role, let paneID, let until, let timeoutMinutes):
      startRoleWait(session, role: role, paneID: paneID, until: until, timeoutMinutes: timeoutMinutes)
    case .cancelRoleWait(let role):
      session.roleWaits[role]?.cancel()
      session.roleWaits[role] = nil
    case .openActivation(let ordinal, let paneID, let token):
      registry.open(runID: session.id, ordinal: ordinal, paneID: paneID, token: token)
    case .revokeActivation(let ordinal):
      registry.revoke(runID: session.id, ordinal: ordinal)
    case .materializeInstruction(let ordinal, let stepID, let text):
      await materializeInstruction(session, ordinal: ordinal, stepID: stepID, text: text)
    case .inject(let paneID, let ordinal, let line):
      inject(session, paneID: paneID, ordinal: ordinal, line: line)
    case .launch(let request):
      launch(session, request: request)
    case .runCommand(let stepID, let ordinal, let command, let workingDirectory, let environment, let timeoutSeconds):
      runCommand(
        session, stepID: stepID, ordinal: ordinal, command: command, workingDirectory: workingDirectory,
        environment: environment, timeoutSeconds: timeoutSeconds)
    case .armWatchdog(let ordinal, let idleGraceSeconds, let deadline):
      armWatchdog(session, ordinal: ordinal, idleGraceSeconds: idleGraceSeconds, deadline: deadline)
    case .disarmWatchdog(let ordinal):
      session.watchdogs[ordinal]?.cancel()
      session.watchdogs[ordinal] = nil
    case .notify(let title, let body):
      dependencies.notify(title, body, session.focusPaneID)
    case .closePane(let paneID, _):
      closePane(session, paneID: paneID)
    case .persistDelivery(let ordinal, let name, let body, _, _):
      await persistDelivery(session, ordinal: ordinal, name: name, body: body)
    case .persistRecord:
      await persistRecord(session)
    case .finished(let status):
      await finish(session, status: status)
    }
  }

  // MARK: - Immediate effects

  private func inject(_ session: WorkflowRunSession, paneID: PaneID, ordinal: Int, line: String) {
    if dependencies.sendLine(paneID, line) {
      apply(.injected(ordinal: ordinal), to: session)
    } else {
      apply(.injectionFailed(ordinal: ordinal, reason: "pane \(paneID) has no terminal surface"), to: session)
    }
  }

  /// Only a pane this run still owns is closed: a pane the user already
  /// repurposed, or one another run took over, is left alone.
  private func closePane(_ session: WorkflowRunSession, paneID: PaneID) {
    guard registry.runID(forPane: paneID) == session.id else { return }
    registry.leave(paneID: paneID, runID: session.id)
    dependencies.closePane(paneID)
  }

  // MARK: - Files

  private func materializeInstruction(_ session: WorkflowRunSession, ordinal: Int, stepID: String, text: String)
    async
  {
    let store = session.store
    do {
      _ = try await Task.detached { try store.writeInstruction(stepID: stepID, ordinal: ordinal, text: text) }.value
    } catch {
      // The pointer line still gets typed; the failure is logged so the
      // missing file is explainable when the agent reports it.
      logger.error("instruction write failed: \(String(describing: error), privacy: .public)")
      session.pendingLog.append("instruction \(stepID).\(ordinal) could not be written: \(error)")
    }
  }

  private func persistDelivery(_ session: WorkflowRunSession, ordinal: Int, name: String, body: String) async {
    let store = session.store
    do {
      let written = try await Task.detached { try store.writeDelivery(name: name, ordinal: ordinal, body: body) }
        .value
      apply(
        .deliveryPersisted(
          ordinal: ordinal, path: written.path.path(percentEncoded: false),
          latestPath: written.latest.path(percentEncoded: false)),
        to: session)
    } catch {
      apply(.deliveryPersistFailed(ordinal: ordinal, reason: String(describing: error)), to: session)
    }
  }

  func persistRecord(_ session: WorkflowRunSession) async {
    let store = session.store
    let record = session.machine.run.record
    let lines = session.pendingLog
    session.pendingLog = []
    do {
      try await Task.detached {
        try store.writeRecord(record)
        try store.appendLog(lines)
      }.value
    } catch {
      logger.error("record write failed: \(String(describing: error), privacy: .public)")
    }
  }

  // MARK: - Launch

  private func launch(_ session: WorkflowRunSession, request: WorkflowLaunchRequest) {
    guard let profile = dependencies.profile(request.profileID) else {
      apply(
        .launchFailed(ordinal: request.ordinal, reason: "profile \(request.profileID) no longer exists"), to: session)
      return
    }
    let source = session.run.configuration.source
    session.launchTask?.cancel()
    session.launchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let paneID = try await dependencies.launch(request, source, profile)
        guard !Task.isCancelled else { return }
        registry.bind(runID: session.id, ordinal: request.ordinal, paneID: paneID)
        remember(session, role: request.role, profileID: profile.id)
        apply(.launched(ordinal: request.ordinal, paneID: paneID), to: session)
      } catch {
        guard !Task.isCancelled else { return }
        apply(.launchFailed(ordinal: request.ordinal, reason: String(describing: error)), to: session)
      }
    }
  }

  /// A successful launch is the binding worth remembering for next time.
  private func remember(_ session: WorkflowRunSession, role roleName: String, profileID: UUID) {
    guard let role = session.run.definition.role(named: roleName) else { return }
    dependencies.rememberBinding(
      WorkflowBindingMemory(
        scope: session.entry.scope,
        workflowID: session.entry.id,
        role: roleName,
        requirementsDigest: WorkflowAdmission.requirementsDigest(for: role),
        profileID: profileID))
  }

  // MARK: - Commands

  private func runCommand(
    _ session: WorkflowRunSession,
    stepID: String,
    ordinal: Int,
    command: String,
    workingDirectory: String,
    environment: [String: String],
    timeoutSeconds: Int
  ) {
    let store = session.store
    let runCommand = dependencies.runCommand
    session.commandTask?.cancel()
    session.commandTask = Task { @MainActor [weak self] in
      let outcome = await runCommand(command, workingDirectory, environment, timeoutSeconds)
      let result = CommandResult(outcome)
      let paths = try? await Task.detached {
        try store.writeCommandOutput(stepID: stepID, ordinal: ordinal, stdout: result.stdout, stderr: result.stderr)
      }.value
      guard let self else { return }
      apply(
        .commandFinished(
          stepID: stepID,
          exitCode: result.exitCode,
          stdout: result.stdout,
          stdoutPath: paths?.stdoutURL.path(percentEncoded: false)
            ?? WorkflowRunLayout.stdoutURL(runDirectory: store.runDirectory, stepID: stepID, ordinal: ordinal)
            .path(percentEncoded: false),
          timedOut: result.timedOut,
          spawnFailure: result.spawnFailure),
        to: session)
    }
  }

  private struct CommandResult: Sendable {
    /// UTF-8 when it is, otherwise a byte-preserving Latin-1 reading so a
    /// partial write never loses the output.
    static func text(_ data: Data) -> String {
      String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }

    var exitCode: Int?
    var stdout = ""
    var stderr = ""
    var timedOut = false
    var spawnFailure: String?

    init(_ outcome: CommandOutcome) {
      switch outcome {
      case .exited(let code, let stdout, let stderr, _):
        exitCode = Int(code)
        self.stdout = Self.text(stdout)
        self.stderr = Self.text(stderr)
      case .timedOut:
        timedOut = true
      case .spawnFailed(let reason):
        spawnFailure = reason
      }
    }
  }

  // MARK: - Role polling

  /// Polls the role's pane until the awaited condition holds. `idle` must
  /// hold for `idleHoldSeconds`: the classifier already lags the agent by
  /// a second, and a stable period on top keeps a line from landing in the
  /// gap between two tool calls.
  private func startRoleWait(
    _ session: WorkflowRunSession,
    role: String,
    paneID: PaneID,
    until: WorkflowWaitCondition,
    timeoutMinutes: Int?
  ) {
    session.roleWaits[role]?.cancel()
    let deadline = timeoutMinutes.map { dependencies.now().addingTimeInterval(TimeInterval($0 * 60)) }
    session.roleWaits[role] = Task { @MainActor [weak self] in
      var idleSince: Date?
      var blockedSince: Date?
      while let self, !Task.isCancelled {
        let now = dependencies.now()
        guard dependencies.paneExists(paneID) else {
          apply(until == .exit ? .roleExited(role: role) : .roleGone(role: role), to: session)
          return
        }
        let state = dependencies.agentState(paneID)
        session.machine.observe(role: role, state: state?.rawValue ?? "gone")
        if let deadline, now >= deadline {
          apply(.waitTimedOut(role: role), to: session)
          return
        }
        if let event = roleWaitEvent(
          role: role, until: until, state: state, now: now, idleSince: &idleSince, blockedSince: &blockedSince)
        {
          apply(event, to: session)
          return
        }
        try? await Task.sleep(for: dependencies.pollInterval)
      }
    }
  }

  private func roleWaitEvent(
    role: String,
    until: WorkflowWaitCondition,
    state: AgentStateStore.AgentRuntimeState?,
    now: Date,
    idleSince: inout Date?,
    blockedSince: inout Date?
  ) -> WorkflowRunEvent? {
    let isIdle = state == .idle || state == .finished
    idleSince = isIdle ? (idleSince ?? now) : nil
    blockedSince = state == .blocked ? (blockedSince ?? now) : nil
    switch until {
    case .idle:
      if let since = idleSince, now.timeIntervalSince(since) >= dependencies.idleHoldSeconds {
        return .roleIdle(role: role)
      }
    case .exit:
      if state == nil { return .roleExited(role: role) }
    case .blocked:
      if state == .blocked { return .roleBlocked(role: role) }
    }
    if let since = blockedSince, now.timeIntervalSince(since) >= dependencies.blockedHoldSeconds {
      return .roleBlocked(role: role)
    }
    return nil
  }

  // MARK: - Watchdog

  /// While a delivery is awaited the role's pane is watched for the
  /// machine: working → idle for the grace period, the deadline, a pane
  /// stuck on a prompt, or a pane that vanished. Re-arming replaces.
  private func armWatchdog(_ session: WorkflowRunSession, ordinal: Int, idleGraceSeconds: Int, deadline: Date?) {
    session.watchdogs[ordinal]?.cancel()
    guard let activation = session.machine.run.activations[ordinal], let paneID = activation.paneID else { return }
    let role = activation.role
    // After a nudge the agent may never start working again; the second
    // grace must count from idle as it is.
    let alreadyNudged = activation.nudged
    session.watchdogs[ordinal] = Task { @MainActor [weak self] in
      var seenWorking = alreadyNudged
      var idleSince: Date?
      var blockedSince: Date?
      while let self, !Task.isCancelled {
        let now = dependencies.now()
        guard dependencies.paneExists(paneID) else {
          apply(.roleGone(role: role), to: session)
          return
        }
        let state = dependencies.agentState(paneID)
        session.machine.observe(role: role, state: state?.rawValue ?? "gone")
        if let deadline, now >= deadline {
          apply(.watchdog(ordinal: ordinal, .deadlineReached), to: session)
          return
        }
        if state == .working { seenWorking = true }
        let isIdle = seenWorking && (state == .idle || state == .finished)
        idleSince = isIdle ? (idleSince ?? now) : nil
        blockedSince = state == .blocked ? (blockedSince ?? now) : nil
        if let since = idleSince, now.timeIntervalSince(since) >= TimeInterval(idleGraceSeconds) {
          apply(.watchdog(ordinal: ordinal, .idleGraceElapsed), to: session)
          return
        }
        if let since = blockedSince, now.timeIntervalSince(since) >= dependencies.blockedHoldSeconds {
          apply(.roleBlocked(role: role), to: session)
          return
        }
        try? await Task.sleep(for: dependencies.pollInterval)
      }
    }
  }
}
