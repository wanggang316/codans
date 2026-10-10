import Foundation

/// Cross-reference checks over a parsed `WorkflowDefinition`: every name a
/// step or expression uses must be one the workflow can actually provide.
/// Runs only on a definition the parser accepted, so it never has to guess
/// about shape — only about meaning.
///
/// Ordering is deliberately not checked in this version: a delivery counts as
/// produced if any step anywhere in the file produces it. The run machine
/// reports a genuinely missing value at the step that needs it, which is the
/// same error an author would get from a stricter static pass, just later.
public nonisolated enum WorkflowValidator {
  public static func validate(_ definition: WorkflowDefinition) -> [WorkflowDiagnostic] {
    var checker = Checker(definition: definition)
    checker.run()
    return checker.diagnostics
  }

  /// Steps whose `expect.delivery` is `delivery`, in document order.
  public static func producers(of delivery: String, in definition: WorkflowDefinition) -> [WorkflowStep] {
    definition.flattenedSteps.filter { $0.expectation?.delivery == delivery }
  }

  /// Steps that cannot run without `deliveries.<delivery>`: any expression or
  /// template on the step names it outside an `exists()` / `??` guard. The
  /// skip-consequence analysis leans on this to say which steps a skipped
  /// delivery would take down with it.
  public static func consumers(of delivery: String, in definition: WorkflowDefinition) -> [WorkflowStep] {
    definition.flattenedSteps.filter { step in
      Sites.requiredReferences(of: step).contains { reference in
        reference.namespace == "deliveries" && reference.path.count >= 2 && reference.path[1] == delivery
      }
    }
  }
}

// MARK: - Expression sites

extension WorkflowValidator {
  /// Where expressions live on a step, each with the path a diagnostic cites.
  enum Sites {
    struct ExpressionSite {
      let path: String
      let expression: WorkflowExpression
    }

    struct TemplateSite {
      let path: String
      let template: WorkflowTemplate
      /// Rendered text that ends up typed into an agent's pane — where the
      /// renderer appends the completion command itself.
      let addressesAgent: Bool
    }

    static func expressions(of step: WorkflowStep) -> [ExpressionSite] {
      var sites: [ExpressionSite] = []
      if let condition = step.condition {
        sites.append(ExpressionSite(path: "\(step.path).if", expression: condition))
      }
      if case .loop(let condition, _, _) = step.verb {
        sites.append(ExpressionSite(path: "\(step.path).while", expression: condition))
      }
      return sites
    }

    static func templates(of step: WorkflowStep) -> [TemplateSite] {
      let base = step.path
      switch step.verb {
      case .message(_, let content, _):
        switch content {
        case .text(let template):
          return [TemplateSite(path: "\(base).text", template: template, addressesAgent: true)]
        case .instruction(let template):
          return [TemplateSite(path: "\(base).instruction", template: template, addressesAgent: true)]
        }
      case .launch(_, let prompt, _):
        return [TemplateSite(path: "\(base).prompt", template: prompt, addressesAgent: true)]
      case .run(let run):
        var sites = [TemplateSite(path: "\(base).run", template: run.command, addressesAgent: false)]
        if let workingDirectory = run.workingDirectory {
          sites.append(
            TemplateSite(path: "\(base).working-directory", template: workingDirectory, addressesAgent: false))
        }
        for key in run.env.keys.sorted() {
          if let value = run.env[key] {
            sites.append(TemplateSite(path: "\(base).env.\(key)", template: value, addressesAgent: false))
          }
        }
        return sites
      case .notify(let template):
        return [TemplateSite(path: "\(base).notify", template: template, addressesAgent: false)]
      case .set(let assignments):
        return assignments.map {
          TemplateSite(path: "\(base).set.\($0.name)", template: $0.value, addressesAgent: false)
        }
      case .wait, .close, .loop, .breakLoop, .continueLoop:
        return []
      }
    }

    static func requiredReferences(of step: WorkflowStep) -> [WorkflowReference] {
      expressions(of: step).flatMap(\.expression.references) + templates(of: step).flatMap(\.template.references)
    }

    static func allReferences(of step: WorkflowStep) -> [WorkflowReference] {
      expressions(of: step).flatMap(\.expression.allReferences)
        + templates(of: step).flatMap(\.template.allReferences)
    }
  }
}

// MARK: - Checker

extension WorkflowValidator {
  private struct Checker {
    let definition: WorkflowDefinition
    var diagnostics: [WorkflowDiagnostic] = []

    private var launchedRoles: Set<String> = []
    private var referencedRoles: Set<String> = []
    private var referencedInputs: Set<String> = []
    private var explicitStepIDs: Set<String> = []

    /// Members the run machine publishes for the fixed namespaces.
    private static let fixedMembers: [String: Set<String>] = [
      "workflow": ["id", "name"],
      "run": ["id", "path"],
      "worktree": ["id", "path", "name", "branch"],
      "loop": ["iteration"],
      "codans": ["cli"],
    ]
    private static let roleMembers: Set<String> = ["pane-id", "agent", "name", "state"]
    private static let deliveryMembers: Set<String> = ["path", "verdict"]
    private static let stepMembers: Set<String> = ["outcome", "outputs"]

    init(definition: WorkflowDefinition) {
      self.definition = definition
      explicitStepIDs = Set(definition.flattenedSteps.filter(\.hasExplicitID).map(\.id))
    }

    mutating func run() {
      checkRoles()
      checkStepIDs()
      walk(definition.steps, loopDepth: 0)
      checkUnused()
    }

    // MARK: Definition-wide

    private mutating func checkRoles() {
      let current = definition.roles.filter { $0.source == .current }
      if current.count > 1 {
        let names = current.map(\.name).joined(separator: ", ")
        report(
          .error("multiple_current_roles", "only one role may have `source: current`, found: \(names)", at: "roles"))
      }
    }

    private mutating func checkStepIDs() {
      var seen: Set<String> = []
      for step in definition.flattenedSteps where !seen.insert(step.id).inserted {
        report(.error("duplicate_step_id", "step id `\(step.id)` is used more than once", at: "\(step.path).id"))
      }
    }

    private mutating func checkUnused() {
      for role in definition.roles where !referencedRoles.contains(role.name) {
        report(.warning("unused_role", "role `\(role.name)` is never used by a step", at: "roles.\(role.name)"))
      }
      for input in definition.inputs where !referencedInputs.contains(input.name) {
        report(.warning("unused_input", "input `\(input.name)` is never referenced", at: "inputs.\(input.name)"))
      }
    }

    // MARK: Steps

    private mutating func walk(_ steps: [WorkflowStep], loopDepth: Int) {
      for step in steps {
        checkStep(step, loopDepth: loopDepth)
        if case .loop(_, _, let body) = step.verb {
          walk(body, loopDepth: loopDepth + 1)
        }
      }
    }

    private mutating func checkStep(_ step: WorkflowStep, loopDepth: Int) {
      switch step.verb {
      case .message(let role, _, _), .wait(let role, _, _):
        checkRoleExists(role, at: "\(step.path).\(step.verb.keyword)")
      case .launch(let role, _, _):
        checkLaunch(role, step: step, loopDepth: loopDepth)
      case .close(let role):
        if checkRoleExists(role, at: "\(step.path).close"), definition.role(named: role)?.source != .launch {
          report(
            .error("launch_role_source", "`close` only applies to a `source: launch` role", at: "\(step.path).close"))
        }
      case .run(let run):
        if let role = run.inRole {
          referencedRoles.insert(role)
          if definition.role(named: role) == nil {
            report(.error("run_in_role_source", "`in` names an undefined role `\(role)`", at: "\(step.path).in"))
          }
        }
      case .set(let assignments):
        for assignment in assignments where !definition.state.contains(where: { $0.name == assignment.name }) {
          report(
            .error(
              "set_unknown_state", "`\(assignment.name)` is not declared under `state`",
              at: "\(step.path).set.\(assignment.name)"))
        }
      case .breakLoop where loopDepth == 0:
        report(.error("break_outside_loop", "`break` is only valid inside a `while` body", at: step.path))
      case .continueLoop where loopDepth == 0:
        report(.error("continue_outside_loop", "`continue` is only valid inside a `while` body", at: step.path))
      case .notify, .loop, .breakLoop, .continueLoop:
        break
      }
      checkReferences(of: step)
      checkHandWrittenDeliver(in: step)
    }

    private mutating func checkLaunch(_ role: String, step: WorkflowStep, loopDepth: Int) {
      let path = "\(step.path).launch"
      guard checkRoleExists(role, at: path) else { return }
      if definition.role(named: role)?.source != .launch {
        report(.error("launch_role_source", "`launch` needs a `source: launch` role", at: path))
      }
      if !launchedRoles.insert(role).inserted {
        report(.error("launch_twice", "role `\(role)` is launched by more than one step", at: path))
      }
      if loopDepth > 0 {
        report(.error("launch_in_loop", "`launch` cannot sit inside a `while` body", at: path))
      }
    }

    @discardableResult
    private mutating func checkRoleExists(_ role: String, at path: String) -> Bool {
      referencedRoles.insert(role)
      guard definition.role(named: role) != nil else {
        report(.error("undefined_role", "role `\(role)` is not declared under `roles`", at: path))
        return false
      }
      return true
    }

    // MARK: References

    private mutating func checkReferences(of step: WorkflowStep) {
      for site in Sites.expressions(of: step) {
        noteAllReferences(site.expression.allReferences, at: site.path)
        for reference in site.expression.references {
          checkReference(reference, at: site.path)
        }
      }
      for site in Sites.templates(of: step) {
        noteAllReferences(site.template.allReferences, at: site.path)
        for reference in site.template.references {
          checkReference(reference, at: site.path)
        }
      }
    }

    /// Guarded references still count as use, and a `verdict` read is worth
    /// a warning whether or not it is guarded.
    private mutating func noteAllReferences(_ references: [WorkflowReference], at path: String) {
      for reference in references where reference.path.count >= 2 {
        switch reference.namespace {
        case "inputs": referencedInputs.insert(reference.path[1])
        case "roles": referencedRoles.insert(reference.path[1])
        case "deliveries": checkVerdictRead(reference, at: path)
        default: break
        }
      }
    }

    private mutating func checkVerdictRead(_ reference: WorkflowReference, at path: String) {
      guard reference.path.count >= 3, reference.path[2] == "verdict" else { return }
      let producers = WorkflowValidator.producers(of: reference.path[1], in: definition)
      guard !producers.isEmpty, producers.allSatisfy({ $0.expectation?.verdicts == nil }) else { return }
      report(
        .warning(
          "verdict_without_verdicts",
          "`\(reference)` is read but no `expect` for `\(reference.path[1])` declares `verdicts`", at: path))
    }

    private mutating func checkReference(_ reference: WorkflowReference, at path: String) {
      let segments = reference.path
      let failure: String?
      switch reference.namespace {
      case "inputs":
        failure = memberFailure(segments, among: Set(definition.inputs.map(\.name)), depth: 2, kind: "input")
      case "state":
        failure = memberFailure(segments, among: Set(definition.state.map(\.name)), depth: 2, kind: "state variable")
      case "roles":
        let roles = Set(definition.roles.map(\.name))
        failure =
          memberFailure(segments, among: roles, depth: 2, kind: "role", openMembers: roles)
          ?? memberFailure(segments, among: Self.roleMembers, depth: 3, kind: "role property")
      case "steps":
        failure =
          memberFailure(
            segments, among: explicitStepIDs, depth: 2, kind: "step with an explicit `id`", openMembers: explicitStepIDs
          )
          ?? memberFailure(segments, among: Self.stepMembers, depth: 3, kind: "step property", openMembers: ["outputs"])
      case "deliveries":
        let deliveries = producedDeliveries
        failure =
          memberFailure(
            segments, among: deliveries, depth: 2, kind: "delivery produced by an `expect`", openMembers: deliveries)
          ?? memberFailure(segments, among: Self.deliveryMembers, depth: 3, kind: "delivery property")
      case let namespace where Self.fixedMembers[namespace] != nil:
        failure = memberFailure(segments, among: Self.fixedMembers[namespace] ?? [], depth: 2, kind: "member")
      default:
        failure = "`\(reference.namespace)` is not a workflow namespace"
      }
      if let failure {
        report(.error("unknown_reference", "`\(reference)`: \(failure)", at: path))
      }
    }

    private var producedDeliveries: Set<String> {
      Set(definition.flattenedSteps.compactMap { $0.expectation?.delivery })
    }

    /// Checks the segment at `depth` (1-based) against `allowed`. A missing
    /// segment at that depth is an error too — a bare namespace is never a
    /// value — and so is anything past a member not listed in `openMembers`
    /// (`inputs.n` is a scalar; `steps.<id>.outputs` carries arbitrary names).
    private func memberFailure(
      _ segments: [String], among allowed: Set<String>, depth: Int, kind: String, openMembers: Set<String> = []
    ) -> String? {
      guard segments.count >= depth else {
        return "expected a \(kind) after `\(segments.joined(separator: "."))`"
      }
      let member = segments[depth - 1]
      guard allowed.contains(member) else {
        return "`\(member)` is not a \(kind)"
      }
      if segments.count > depth, !openMembers.contains(member) {
        return "`\(segments[..<depth].joined(separator: "."))` has no member `\(segments[depth])`"
      }
      return nil
    }

    // MARK: Text

    private mutating func checkHandWrittenDeliver(in step: WorkflowStep) {
      for site in Sites.templates(of: step) where site.addressesAgent {
        let handWritten = site.template.segments.contains {
          if case .literal(let text) = $0 { return text.contains("workflow deliver") }
          return false
        }
        if handWritten {
          report(
            .warning(
              "deliver_in_text",
              "do not spell out `codans workflow deliver`; the completion command is appended automatically",
              at: site.path))
        }
      }
    }

    private mutating func report(_ diagnostic: WorkflowDiagnostic) {
      diagnostics.append(diagnostic)
    }
  }
}
