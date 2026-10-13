import Foundation
import Testing

@testable import CodansCore

/// Cross-reference rules over parsed definitions. Documents are built through
/// the parser so the tests read like the files an author would write.
struct WorkflowValidatorTests {
  private func definition(_ yaml: String) throws -> WorkflowDefinition {
    let result = WorkflowDocumentParser.parse(yaml: yaml, id: "test")
    #expect(result.diagnostics.isEmpty, "parser diagnostics: \(result.diagnostics)")
    return try #require(result.definition)
  }

  private func validate(_ yaml: String) throws -> [WorkflowDiagnostic] {
    WorkflowValidator.validate(try definition(yaml))
  }

  private func paths(of code: String, in yaml: String) throws -> [String?] {
    try validate(yaml).filter { $0.code == code }.map(\.path)
  }

  /// A document with one `current` role `me`, one `launch` role `bot`, an
  /// input `n` and a state variable `count`, all used, so that only the
  /// steps under test add diagnostics.
  private func document(_ steps: String) -> String {
    """
    name: T
    inputs:
      n: {type: number, default: 1}
    roles:
      me: {source: current}
      bot: {source: launch}
    state:
      count: 0
    steps:
      - launch: bot
        prompt: Count to ${{ inputs.n }}
        expect: {delivery: report, verdicts: [done, stuck]}
      - message: me
        text: See ${{ deliveries.report.path }} (${{ state.count }})
    \(steps)
    """
  }

  // MARK: - Baseline

  @Test
  func theDesignDocSampleIsClean() throws {
    #expect(try validate(WorkflowDocumentParserTests.reviewLoop).isEmpty)
    #expect(try validate(document("")).isEmpty)
  }

  // MARK: - Roles

  @Test
  func stepsMustNameDeclaredRoles() throws {
    let yaml = document(
      """
        - message: ghost
          text: hi
        - wait: ghost
        - close: ghost
        - launch: ghost
          prompt: p
        - run: ls
          in: ghost
      """)
    #expect(
      try paths(of: "undefined_role", in: yaml) == [
        "steps[2].message", "steps[3].wait", "steps[4].close", "steps[5].launch",
      ])
    #expect(try paths(of: "run_in_role_source", in: yaml) == ["steps[6].in"])
  }

  @Test
  func launchAndCloseOnlyApplyToLaunchRoles() throws {
    let yaml = document(
      """
        - launch: me
          prompt: p
        - close: me
        - close: bot
      """)
    #expect(try paths(of: "launch_role_source", in: yaml) == ["steps[2].launch", "steps[3].close"])
  }

  @Test
  func aLaunchRoleIsLaunchedOnce() throws {
    let yaml = document(
      """
        - if: state.count == 0
          launch: bot
          prompt: again
      """)
    #expect(try paths(of: "launch_twice", in: yaml) == ["steps[2].launch"])
  }

  @Test
  func launchCannotSitInsideALoop() throws {
    let yaml = """
      name: T
      roles:
        bot: {source: launch}
      steps:
        - while: true
          steps:
            - launch: bot
              prompt: p
      """
    #expect(try paths(of: "launch_in_loop", in: yaml) == ["steps[0].steps[0].launch"])
  }

  @Test
  func onlyOneCurrentRole() throws {
    let yaml = """
      name: T
      roles:
        a: {source: current}
        b: {source: current}
      steps:
        - message: a
          text: x
        - message: b
          text: y
      """
    #expect(try paths(of: "multiple_current_roles", in: yaml) == ["roles"])
  }

  @Test
  func unusedRolesAndInputsWarn() throws {
    let yaml = """
      name: T
      inputs:
        used: {default: a}
        guarded: {default: b}
        unused: {default: c}
      roles:
        me: {source: current}
        spare: {source: pick}
        watched: {source: pick}
      steps:
        - if: roles.watched.state == 'idle'
          message: me
          text: ${{ inputs.used }} ${{ inputs.guarded ?? 'x' }}
      """
    let diagnostics = try validate(yaml)
    #expect(diagnostics.map(\.severity) == [.warning, .warning])
    #expect(diagnostics.map(\.code) == ["unused_role", "unused_input"])
    #expect(diagnostics.map(\.path) == ["roles.spare", "inputs.unused"])
  }

  // MARK: - Control flow

  @Test
  func duplicateStepIDsAreAnError() throws {
    let steps = [
      WorkflowStep(id: "a", verb: .notify(.literal("1")), path: "steps[0]"),
      WorkflowStep(id: "a", verb: .notify(.literal("2")), path: "steps[1]"),
    ]
    let diagnostics = WorkflowValidator.validate(WorkflowDefinition(id: "t", name: "T", steps: steps))
    #expect(diagnostics == [.error("duplicate_step_id", "step id `a` is used more than once", at: "steps[1].id")])
  }

  @Test
  func breakAndContinueBelongInsideLoops() throws {
    let yaml = """
      name: T
      steps:
        - break: true
        - continue: true
        - while: true
          steps:
            - break: true
            - continue: true
      """
    #expect(try paths(of: "break_outside_loop", in: yaml) == ["steps[0]"])
    #expect(try paths(of: "continue_outside_loop", in: yaml) == ["steps[1]"])
  }

  @Test
  func setOnlyAssignsDeclaredState() throws {
    let yaml = document(
      """
        - set: {count: 1, other: 2}
      """)
    #expect(try paths(of: "set_unknown_state", in: yaml) == ["steps[2].set.other"])
  }

  // MARK: - References

  @Test
  func referencesMustPointAtSomethingTheWorkflowProvides() throws {
    let yaml = document(
      """
        - if: inputs.missing == 1
          notify: a
        - if: state.missing == 1
          notify: b
        - if: roles.ghost.state == 'idle'
          notify: c
        - if: roles.bot.pane == 1
          notify: d
        - if: deliveries.nothing.path == ''
          notify: e
        - if: deliveries.report.body == ''
          notify: f
        - if: steps.step-1.outcome == 'success'
          notify: g
        - if: secrets.token == ''
          notify: h
        - if: workflow.version == 1
          notify: i
        - if: inputs == 1
          notify: j
      """)
    #expect(
      try paths(of: "unknown_reference", in: yaml) == [
        "steps[2].if", "steps[3].if", "steps[4].if", "steps[5].if", "steps[6].if", "steps[7].if", "steps[8].if",
        "steps[9].if", "steps[10].if", "steps[11].if",
      ])
  }

  @Test
  func referencesAreCheckedInEveryTemplateSite() throws {
    let yaml = document(
      """
        - run: echo ${{ inputs.a }}
          working-directory: ${{ inputs.b }}
          env: {X: "${{ inputs.c }}"}
        - notify: ${{ inputs.d }}
        - set: {count: "${{ inputs.e }}"}
        - while: inputs.f == 1
          steps:
            - message: me
              instruction: ${{ inputs.g }}
      """)
    #expect(
      try paths(of: "unknown_reference", in: yaml) == [
        "steps[2].run", "steps[2].working-directory", "steps[2].env.X", "steps[3].notify", "steps[4].set.count",
        "steps[5].while", "steps[5].steps[0].instruction",
      ])
  }

  @Test
  func knownNamespacesAndMembersPass() throws {
    let yaml = document(
      """
        - id: lint
          run: ${{ codans.cli }} tree
        - if: >-
            workflow.id == 'x' && workflow.name == 'y' && run.id == 'r' && run.path == '/p'
            && worktree.id == 'w' && worktree.path == '/w' && worktree.name == 'n' && worktree.branch == 'b'
            && (loop.iteration ?? 0) == 0 && roles.bot.pane-id == 'p1' && roles.bot.agent == 'codex'
            && roles.me.name == 'me' && steps.lint.outcome == 'success' && steps.lint.outputs.exit-code == 0
            && deliveries.report.verdict == 'done'
          notify: all good
      """)
    #expect(try validate(yaml).isEmpty)
  }

  @Test
  func guardedReferencesAreNotRequired() throws {
    let yaml = document(
      """
        - if: exists(deliveries.later.path) || (deliveries.later.verdict ?? 'none') == 'x'
          notify: ${{ inputs.absent ?? 'default' }}
      """)
    #expect(try validate(yaml).isEmpty)
  }

  @Test
  func stepsReferencesNeedAnExplicitID() throws {
    let yaml = document(
      """
        - run: true
        - if: steps.step-3.outcome == 'success'
          notify: implicit ids are not addressable
      """)
    #expect(try paths(of: "unknown_reference", in: yaml) == ["steps[3].if"])
  }

  @Test
  func verdictReadsWarnWhenNoProducerDeclaresVerdicts() throws {
    let yaml = """
      name: T
      roles:
        me: {source: current}
      steps:
        - message: me
          text: go
          expect: {delivery: notes}
        - if: deliveries.notes.verdict == 'ok'
          notify: ${{ deliveries.notes.verdict ?? 'none' }}
      """
    #expect(try paths(of: "verdict_without_verdicts", in: yaml) == ["steps[1].if", "steps[1].notify"])
  }

  @Test
  func handWrittenDeliverCommandsWarn() throws {
    let yaml = document(
      """
        - message: me
          text: When done run codans workflow deliver -
        - message: me
          instruction: |
            Finish with `codans workflow deliver --verdict done -`.
        - notify: codans workflow deliver is appended automatically
      """)
    #expect(try paths(of: "deliver_in_text", in: yaml) == ["steps[2].text", "steps[3].instruction"])
    #expect(try validate(yaml).allSatisfy { $0.severity == .warning })
  }

  // MARK: - Producers and consumers

  @Test
  func producersAndConsumersOfADelivery() throws {
    let definition = try definition(WorkflowDocumentParserTests.reviewLoop)
    #expect(
      WorkflowValidator.producers(of: "review", in: definition).map(\.id) == ["kickoff", "step-5"])
    #expect(WorkflowValidator.producers(of: "fixes", in: definition).map(\.id) == ["step-4"])
    #expect(WorkflowValidator.producers(of: "none", in: definition).isEmpty)

    #expect(
      WorkflowValidator.consumers(of: "review", in: definition).map(\.id) == ["step-4", "step-6", "step-8"])
    #expect(WorkflowValidator.consumers(of: "fixes", in: definition).map(\.id) == ["step-5"])
  }

  @Test
  func guardedConsumersAreNotConsumers() throws {
    let yaml = document(
      """
        - if: exists(deliveries.report.verdict)
          notify: ${{ deliveries.report.verdict ?? 'none' }}
        - if: deliveries.report.verdict == 'done'
          notify: strict
      """)
    let definition = try definition(yaml)
    #expect(WorkflowValidator.consumers(of: "report", in: definition).map(\.id) == ["step-2", "step-4"])
  }
}
