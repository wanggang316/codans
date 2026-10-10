import Foundation

/// Delivery intake, the expression context, and skip-consequence
/// analysis — the three places the machine reads its own state back.
extension WorkflowMachine {
  // MARK: - Deliver

  /// Takes a `codans workflow deliver` body for the activation `ordinal`.
  /// `token` must match unless `allowManual` (the caller named the run
  /// and step explicitly). Accepted and provisional deliveries both move
  /// the activation to `persisting`; the run only advances once the
  /// engine reports `deliveryPersisted`. `force` keeps a body that a
  /// `strict` step would refuse for missing sections or verdict, as a
  /// provisional delivery for the user to judge; hard rejections (empty,
  /// oversized, unknown verdict) still refuse.
  public mutating func deliver(
    ordinal: Int,
    token: String?,
    allowManual: Bool = false,
    force: Bool = false,
    body: String,
    verdict: String?,
    now: Date
  ) -> (outcome: WorkflowDeliveryOutcome, effects: [WorkflowEffect]) {
    var outcome = WorkflowDeliveryOutcome.rejected(code: "STEP_NOT_EXPECTING", message: "the run has ended")
    // No activation is minted on delivery, so the token mint is inert.
    let effects = transition(
      now: now, makeToken: { "" },
      { machine, transition in
        guard !machine.run.status.isTerminal else { return }
        outcome = machine.performDeliver(
          ordinal: ordinal, token: token, allowManual: allowManual, force: force, body: body, verdict: verdict,
          &transition)
      })
    return (outcome, effects)
  }

  private mutating func performDeliver(
    ordinal: Int,
    token: String?,
    allowManual: Bool,
    force: Bool,
    body: String,
    verdict: String?,
    _ transition: inout Transition
  ) -> WorkflowDeliveryOutcome {
    guard ordinal == run.currentOrdinal, var activation = run.activations[ordinal], activation.state == .waiting
    else {
      return .rejected(code: "STEP_NOT_EXPECTING", message: "no step is waiting for delivery #\(ordinal)")
    }
    if let token {
      guard token == activation.token else {
        return .rejected(code: "TOKEN_INVALID", message: "the token does not match the waiting activation")
      }
    } else if !allowManual {
      return .rejected(code: "TOKEN_REQUIRED", message: "a workflow token is required to deliver")
    }
    let result = WorkflowDeliveryValidator.validate(body: body, verdict: verdict, expectation: activation.expectation)
    if let rejection = result.rejection {
      return .rejected(code: rejection.code, message: rejection.message)
    }
    let issues = result.issues.map(\.message)
    if !issues.isEmpty, activation.expectation.strict, !force, let first = result.issues.first {
      return .rejected(code: first.code, message: issues.joined(separator: "; "))
    }
    activation.state = .persisting
    activation.issues = issues
    activation.verdict = verdict
    activation.pendingLine = nil
    run.activations[ordinal] = activation
    transition.effects.append(
      .persistDelivery(
        ordinal: ordinal, name: activation.delivery, body: result.normalizedBody, verdict: verdict,
        provisional: !issues.isEmpty))
    let summary = issues.isEmpty ? "accepted" : "provisional (\(issues.joined(separator: "; ")))"
    log("delivery \(activation.delivery)#\(ordinal): \(summary)", &transition)
    return issues.isEmpty ? .accepted : .provisional(issues: issues)
  }

  // MARK: - Skip consequence

  /// The first step that would fail without `name`: any step still ahead
  /// of the cursor — the rest of the document, the whole body of every
  /// enclosing loop (it runs again) and those loops' conditions — whose
  /// required references name `deliveries.<name>`. `nil` when nothing
  /// does, or when an earlier delivery under that name already exists.
  public func skipConsequence(forDelivery name: String) -> String? {
    if run.deliveries[name] != nil { return nil }
    guard let currentID = run.currentStepID else { return nil }
    let flattened = run.definition.flattenedSteps
    guard let position = flattened.firstIndex(where: { $0.id == currentID }) else { return nil }
    var candidates = Set(flattened[(position + 1)...].map(\.id))
    for loop in run.cursor.enclosingLoops(in: run.definition) {
      candidates.insert(loop.id)
      if case .loop(_, _, let body) = loop.verb {
        candidates.formUnion(WorkflowStep.flatten(body).map(\.id))
      }
    }
    candidates.remove(currentID)
    return flattened.first { step in
      candidates.contains(step.id) && step.requiredReferences.contains { $0.names(delivery: name) }
    }?.id
  }

  // MARK: - Context

  /// The namespaces an expression sees right now. Every declared role and
  /// state variable is present (unknown facts are `null`), so only names
  /// the workflow never produces throw `missingReference`.
  public func context() -> WorkflowContext {
    let configuration = run.configuration
    var roles: [String: WorkflowValue] = [:]
    for role in run.definition.roles {
      roles[role.name] = roleValue(role.name)
    }
    var steps: [String: WorkflowValue] = [:]
    for (id, record) in run.steps {
      steps[id] = .object([
        "outcome": record.outcome.map { .string($0.rawValue) } ?? .null,
        "outputs": run.stepOutputs[id] ?? .object([:]),
      ])
    }
    var deliveries: [String: WorkflowValue] = [:]
    for (name, record) in run.deliveries {
      deliveries[name] = .object([
        "path": .string(record.path),
        "verdict": record.verdict.map(WorkflowValue.string) ?? .null,
      ])
    }
    return WorkflowContext([
      "workflow": .object(["id": .string(run.definition.id), "name": .string(run.definition.name)]),
      "run": .object(["id": .string(run.id.uuidString), "path": .string(configuration.runDirectory)]),
      "worktree": .object([
        "id": .string(configuration.source.worktreeID.description),
        "path": .string(configuration.source.worktreePath),
        "name": .string(configuration.source.worktreeName),
        "branch": configuration.source.branch.map(WorkflowValue.string) ?? .null,
      ]),
      "roles": .object(roles),
      "inputs": .object(configuration.inputs),
      "state": .object(run.state),
      "steps": .object(steps),
      "deliveries": .object(deliveries),
      "loop": .object(["iteration": run.cursor.iteration.map(WorkflowValue.int) ?? .null]),
      "codans": .object(["cli": .string(configuration.cliCommand)]),
    ])
  }

  private func roleValue(_ name: String) -> WorkflowValue {
    let binding = run.bindings[name]
    var agent: WorkflowValue = .null
    var profileName: WorkflowValue = .null
    if case .launch(_, let launchedName, let launchedAgent, _)? = binding {
      agent = .string(launchedAgent.rawValue)
      profileName = .string(launchedName)
    }
    return .object([
      "pane-id": binding?.paneID.map { .string($0.description) } ?? .null,
      "agent": agent,
      "name": profileName,
      "state": run.roleStates[name].map(WorkflowValue.string) ?? .null,
    ])
  }
}

extension WorkflowStep {
  /// Loop bodies inlined after their loop, document order.
  static func flatten(_ steps: [WorkflowStep]) -> [WorkflowStep] {
    var result: [WorkflowStep] = []
    for step in steps {
      result.append(step)
      if case .loop(_, _, let body) = step.verb {
        result.append(contentsOf: flatten(body))
      }
    }
    return result
  }

  /// References this step cannot evaluate without: its guard plus every
  /// template its verb renders. Loop bodies are not included; they are
  /// steps of their own.
  var requiredReferences: [WorkflowReference] {
    var found = condition?.references ?? []
    var templates: [WorkflowTemplate] = []
    switch verb {
    case .message(_, let content, _):
      templates.append(content.template)
    case .launch(_, let prompt, _):
      templates.append(prompt)
    case .run(let command):
      templates.append(command.command)
      if let directory = command.workingDirectory { templates.append(directory) }
      templates.append(contentsOf: command.env.values)
    case .notify(let template):
      templates.append(template)
    case .set(let assignments):
      templates.append(contentsOf: assignments.map(\.value))
    case .loop(let loopCondition, _, _):
      found.append(contentsOf: loopCondition.references.filter { !found.contains($0) })
    case .wait, .close, .breakLoop, .continueLoop:
      break
    }
    for template in templates {
      found.append(contentsOf: template.references.filter { !found.contains($0) })
    }
    return found
  }
}

extension WorkflowReference {
  /// `deliveries.<name>` or anything below it.
  func names(delivery name: String) -> Bool {
    path.count >= 2 && path[0] == "deliveries" && path[1] == name
  }
}
