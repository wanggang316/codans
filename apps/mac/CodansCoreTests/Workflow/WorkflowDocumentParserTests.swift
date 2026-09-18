import Foundation
import Testing

@testable import CodansCore

/// The parser is the only door a workflow file has into the app, so both the
/// happy path (the design doc's `review-loop`) and every structural
/// diagnostic are pinned here by code and path.
struct WorkflowDocumentParserTests {
  static let reviewLoop = """
    name: Review Loop
    description: Launch a reviewer beside the author and iterate until the review is clean.

    inputs:
      max-rounds:
        description: Stop after this many fix / re-review rounds.
        type: number
        default: 3
      focus:
        description: Anything the reviewer should pay special attention to.
        type: string
        default: ""

    roles:
      author:
        source: current
      reviewer:
        source: launch
        agents: [claude-code, codex]
        profile: Reviewer
        placement: split
        direction: right
        background: true

    state:
      round: 0
      verdict: issues

    steps:
      - name: Launch the reviewer
        id: kickoff
        launch: reviewer
        prompt: |
          Review the uncommitted changes in this worktree. ${{ inputs.focus }}
          Report findings under "## Findings" and finish with a verdict.
        expect:
          delivery: review
          sections: ["## Findings"]
          verdicts: [clean, issues]

      - name: Fix and re-review
        while: state.verdict == 'issues' && state.round < inputs.max-rounds
        max-iterations: 10
        steps:
          - set: {round: "${{ state.round + 1 }}"}
          - name: Ask the author to address the review
            message: author
            instruction: |
              Address the review at ${{ deliveries.review.path }}. Deliver a short summary when done.
            expect: {delivery: fixes}
          - name: Re-review
            message: reviewer
            text: Re-review after the fixes described in ${{ deliveries.fixes.path }}.
            expect: {delivery: review, sections: ["## Findings"], verdicts: [clean, issues]}
          - set: {verdict: "${{ deliveries.review.verdict }}"}

      - if: state.verdict == 'clean'
        notify: Review clean after ${{ state.round }} round(s).
      - if: state.verdict != 'clean'
        notify: Still has issues after ${{ state.round }} round(s); see ${{ deliveries.review.path }}.
    """

  private func parse(_ yaml: String) -> (definition: WorkflowDefinition?, diagnostics: [WorkflowDiagnostic]) {
    WorkflowDocumentParser.parse(yaml: yaml, id: "test")
  }

  /// Paths of every diagnostic with `code`, in report order.
  private func paths(of code: String, in yaml: String) -> [String?] {
    parse(yaml).diagnostics.filter { $0.code == code }.map(\.path)
  }

  private func codes(in yaml: String) -> [String] {
    parse(yaml).diagnostics.map(\.code)
  }

  /// A minimal valid document around `body`.
  private func document(_ body: String) -> String {
    "name: T\n" + body
  }

  // MARK: - The design doc sample

  @Test
  func reviewLoopParsesToTheExpectedDefinition() throws {
    let result = parse(Self.reviewLoop)
    #expect(result.diagnostics.isEmpty)
    let definition = try #require(result.definition)

    #expect(definition.id == "test")
    #expect(definition.name == "Review Loop")
    #expect(definition.description?.hasPrefix("Launch a reviewer") == true)

    #expect(definition.inputs.map(\.name) == ["max-rounds", "focus"])
    #expect(definition.inputs[0].kind == .number)
    #expect(definition.inputs[0].defaultValue == .int(3))
    #expect(definition.inputs[1].kind == .string)
    #expect(definition.inputs[1].defaultValue == .string(""))
    #expect(definition.inputs[1].isRequired == false)

    #expect(definition.roles.map(\.name) == ["author", "reviewer"])
    #expect(definition.roles[0] == WorkflowRole(name: "author", source: .current))
    #expect(
      definition.roles[1]
        == WorkflowRole(
          name: "reviewer", source: .launch, agents: [.claudeCode, .codex], profile: "Reviewer",
          placement: .split, direction: .right, background: true))

    #expect(
      definition.state == [
        WorkflowStateVariable(name: "round", initial: .int(0)),
        WorkflowStateVariable(name: "verdict", initial: .string("issues")),
      ])
  }

  @Test
  func reviewLoopStepsCarryIDsPathsAndExpectations() throws {
    let definition = try #require(parse(Self.reviewLoop).definition)
    #expect(definition.steps.count == 4)
    #expect(
      definition.flattenedSteps.map(\.id)
        == ["kickoff", "step-2", "step-3", "step-4", "step-5", "step-6", "step-7", "step-8"])
    #expect(definition.flattenedSteps.map(\.hasExplicitID) == [true, false, false, false, false, false, false, false])
    #expect(
      definition.flattenedSteps.map(\.path) == [
        "steps[0]", "steps[1]", "steps[1].steps[0]", "steps[1].steps[1]", "steps[1].steps[2]", "steps[1].steps[3]",
        "steps[2]", "steps[3]",
      ])

    let kickoff = definition.steps[0]
    #expect(kickoff.name == "Launch the reviewer")
    guard case .launch(let role, let prompt, let expect) = kickoff.verb else {
      Issue.record("expected a launch step")
      return
    }
    #expect(role == "reviewer")
    #expect(prompt.expressions.map(\.source) == [" inputs.focus "])
    #expect(prompt.source.hasSuffix("finish with a verdict.\n"))
    #expect(
      expect
        == WorkflowExpectation(
          delivery: "review", format: .markdown, sections: ["## Findings"], verdicts: ["clean", "issues"]))

    let loop = definition.steps[1]
    guard case .loop(let condition, let maxIterations, let body) = loop.verb else {
      Issue.record("expected a while step")
      return
    }
    #expect(condition.source == "state.verdict == 'issues' && state.round < inputs.max-rounds")
    #expect(maxIterations == 10)
    #expect(body.count == 4)
    #expect(
      body[0].verb
        == .set([WorkflowAssignment(name: "round", value: try WorkflowTemplate.parse("${{ state.round + 1 }}"))]))
    guard case .message("author", .instruction(let instruction), let fixes) = body[1].verb else {
      Issue.record("expected an instruction message to the author")
      return
    }
    #expect(instruction.references.map(\.description) == ["deliveries.review.path"])
    #expect(fixes == WorkflowExpectation(delivery: "fixes"))
    guard case .message("reviewer", .text, let reReview) = body[2].verb else {
      Issue.record("expected a text message to the reviewer")
      return
    }
    #expect(reReview?.delivery == "review")
    #expect(reReview?.verdicts == ["clean", "issues"])

    #expect(definition.steps[2].condition?.source == "state.verdict == 'clean'")
    guard case .notify(let notify) = definition.steps[3].verb else {
      Issue.record("expected a notify step")
      return
    }
    #expect(notify.references.map(\.description) == ["state.round", "deliveries.review.path"])
  }

  // MARK: - File names

  @Test
  func workflowIDComesFromTheFileName() {
    #expect(WorkflowDocumentParser.workflowID(fromFileName: "review-loop.workflow.yaml") == "review-loop")
    #expect(WorkflowDocumentParser.workflowID(fromFileName: "review-loop.yaml") == nil)
    #expect(WorkflowDocumentParser.workflowID(fromFileName: "Review Loop.workflow.yaml") == nil)
    #expect(WorkflowDocumentParser.workflowID(fromFileName: ".workflow.yaml") == nil)
  }

  // MARK: - Document shape

  @Test
  func malformedDocumentsProduceDiagnosticsNotTraps() {
    #expect(codes(in: "") == ["empty_document"])
    #expect(codes(in: "# only a comment\n") == ["empty_document"])
    #expect(codes(in: "- a\n- b\n") == ["invalid_type"])
    #expect(codes(in: "just a scalar") == ["invalid_type"])
    #expect(codes(in: "name: [unclosed") == ["invalid_yaml"])
    #expect(codes(in: "name: a\nname: b\nsteps: [{notify: x}]") == ["invalid_yaml"])
    #expect(parse("- a").diagnostics.first?.path == nil)
  }

  @Test
  func requiredTopLevelKeysAndUnknownOnes() {
    #expect(paths(of: "missing_key", in: "description: x\n") == ["name", "steps"])
    #expect(paths(of: "unknown_key", in: document("jobs: {}\nsteps: [{notify: x}]")) == ["jobs"])
    #expect(paths(of: "invalid_type", in: document("steps: {notify: x}")) == ["steps"])
    #expect(paths(of: "empty_collection", in: document("steps: []")) == ["steps"])
    #expect(parse(document("steps: []")).definition == nil)
  }

  @Test
  func topLevelSectionsMustBeMappings() {
    #expect(paths(of: "invalid_type", in: document("inputs: [a]\nsteps: [{notify: x}]")) == ["inputs"])
    #expect(paths(of: "invalid_type", in: document("roles: 3\nsteps: [{notify: x}]")) == ["roles"])
    #expect(paths(of: "invalid_type", in: document("state: yes\nsteps: [{notify: x}]")) == ["state"])
  }

  // MARK: - State

  @Test
  func stateLiteralsAreTypedByTheYAMLScalar() throws {
    let yaml = document(
      """
      state:
        count: 0
        flag: true
        label: issues
        quoted: "5"
      steps: [{notify: x}]
      """)
    let definition = try #require(parse(yaml).definition)
    #expect(
      definition.state.map(\.initial) == [.int(0), .bool(true), .string("issues"), .string("5")])
  }

  @Test
  func stateRejectsFloatsNullsAndCollections() {
    let yaml = document(
      """
      state:
        ratio: 1.5
        nothing: null
        list: [1]
        Bad-Name: 1
      steps: [{notify: x}]
      """)
    #expect(paths(of: "invalid_value", in: yaml) == ["state.ratio", "state.nothing"])
    #expect(paths(of: "invalid_type", in: yaml) == ["state.list"])
    #expect(paths(of: "invalid_identifier", in: yaml) == ["state.Bad-Name"])
  }

  // MARK: - Inputs

  @Test
  func inputDefaultsAreTypedAgainstTheirKind() throws {
    let yaml = document(
      """
      inputs:
        n: {type: number, default: 2, min: 1, max: 5}
        b: {type: boolean, default: false}
        s: {default: hello}
        c: {type: choice, options: [a, b], default: b}
        r: {required: true}
      steps: [{notify: x}]
      """)
    let definition = try #require(parse(yaml).definition)
    #expect(definition.inputs.map(\.defaultValue) == [.int(2), .bool(false), .string("hello"), .string("b"), nil])
    #expect(definition.inputs[0].min == 1)
    #expect(definition.inputs[0].max == 5)
    #expect(definition.inputs[3].options == ["a", "b"])
    #expect(definition.inputs[4].isRequired)
    #expect(definition.inputs[4].required)
  }

  @Test
  func inputDefaultMismatchesAreReported() {
    let yaml = document(
      """
      inputs:
        n: {type: number, default: "2"}
        low: {type: number, default: 0, min: 1}
        high: {type: number, default: 9, max: 5}
        b: {type: boolean, default: yes-please}
        s: {default: "two\\nlines"}
        c: {type: choice, options: [a, b], default: z}
      steps: [{notify: x}]
      """)
    #expect(
      paths(of: "invalid_default", in: yaml) == [
        "inputs.n.default", "inputs.low.default", "inputs.high.default", "inputs.b.default", "inputs.s.default",
        "inputs.c.default",
      ])
  }

  @Test
  func inputKeysAreCheckedAgainstTheKind() {
    let yaml = document(
      """
      inputs:
        s: {options: [a], min: 1}
        c: {type: choice}
        e: {type: choice, options: []}
        t: {type: float}
        Bad: {}
        x: {typo: 1}
      steps: [{notify: x}]
      """)
    #expect(paths(of: "key_not_allowed", in: yaml) == ["inputs.s.options", "inputs.s.min"])
    #expect(paths(of: "missing_key", in: yaml) == ["inputs.c.options"])
    #expect(paths(of: "empty_collection", in: yaml) == ["inputs.e.options"])
    #expect(paths(of: "invalid_value", in: yaml) == ["inputs.t.type"])
    #expect(paths(of: "invalid_identifier", in: yaml) == ["inputs.Bad"])
    #expect(paths(of: "unknown_key", in: yaml) == ["inputs.x.typo"])
  }

  // MARK: - Roles

  @Test
  func rolesParseTheirSourceAndLaunchOptions() throws {
    let yaml = document(
      """
      roles:
        me: {source: current}
        other: {source: pick}
        bot: {source: launch, placement: tab, direction: down}
      steps: [{notify: x}]
      """)
    let definition = try #require(parse(yaml).definition)
    #expect(definition.roles.map(\.source) == [.current, .pick, .launch])
    #expect(definition.roles[2].placement == .tab)
    #expect(definition.roles[2].direction == .down)
    #expect(definition.roles[2].agents == nil)
    #expect(definition.roles[2].background == false)
  }

  @Test
  func launchOnlyKeysAreRejectedOnOtherSources() {
    let yaml = document(
      """
      roles:
        me: {source: current, profile: X, background: true}
        none: {}
        odd: {source: remote}
        Bad: {source: pick}
      steps: [{notify: x}]
      """)
    #expect(paths(of: "key_not_allowed", in: yaml) == ["roles.me.profile", "roles.me.background"])
    #expect(paths(of: "missing_key", in: yaml) == ["roles.none.source"])
    #expect(paths(of: "invalid_value", in: yaml) == ["roles.odd.source"])
    #expect(paths(of: "invalid_identifier", in: yaml) == ["roles.Bad"])
  }

  @Test
  func unknownAgentsAreDroppedWithAWarning() throws {
    let yaml = document(
      """
      roles:
        bot: {source: launch, agents: [codex, future-agent]}
      steps: [{notify: x}]
      """)
    let result = parse(yaml)
    #expect(
      result.diagnostics == [
        .warning("unknown_agent", "unknown agent `future-agent` is ignored", at: "roles.bot.agents[1]")
      ])
    #expect(try #require(result.definition).roles[0].agents == [.codex])
  }

  // MARK: - Steps

  @Test
  func synthesizedIDsFollowFlattenedDocumentOrder() throws {
    let yaml = document(
      """
      state: {n: 0}
      steps:
        - notify: one
        - while: state.n < 1
          steps:
            - set: {n: 1}
            - id: inner
              notify: inner
        - notify: last
      """)
    let definition = try #require(parse(yaml).definition)
    #expect(definition.flattenedSteps.map(\.id) == ["step-1", "step-2", "step-3", "inner", "step-5"])
    #expect(definition.step(id: "inner")?.path == "steps[1].steps[1]")
    #expect(definition.step(id: "inner")?.hasExplicitID == true)
    #expect(definition.step(id: "step-5")?.hasExplicitID == false)
  }

  @Test
  func aStepNeedsExactlyOneVerb() {
    let yaml = document(
      """
      steps:
        - name: nothing
        - notify: a
          close: b
        - 42
      """)
    #expect(paths(of: "verb_required", in: yaml) == ["steps[0]"])
    #expect(paths(of: "multiple_verbs", in: yaml) == ["steps[1]"])
    #expect(paths(of: "invalid_type", in: yaml) == ["steps[2]"])
  }

  @Test
  func stepKeysAreCheckedPerVerb() {
    let yaml = document(
      """
      steps:
        - notify: a
          prompt: not here
        - wait: r
          expect: {delivery: x}
        - id: Bad Id
          notify: b
        - id: dup
          notify: c
        - id: dup
          notify: d
      """)
    #expect(paths(of: "unknown_key", in: yaml) == ["steps[0].prompt", "steps[1].expect"])
    #expect(paths(of: "invalid_identifier", in: yaml) == ["steps[2].id"])
    #expect(paths(of: "duplicate_step_id", in: yaml) == ["steps[4].id"])
  }

  @Test
  func conditionsAndTemplatesReportTheirOwnErrors() {
    let yaml = document(
      """
      steps:
        - if: state.n ==
          notify: a
        - notify: unterminated ${{ state.n
        - while: 1 +
          steps: [{notify: x}]
      """)
    #expect(paths(of: "invalid_expression", in: yaml) == ["steps[0].if", "steps[2].while"])
    #expect(paths(of: "invalid_template", in: yaml) == ["steps[1].notify"])
  }

  @Test
  func messageTakesTextOrInstruction() {
    let yaml = document(
      """
      steps:
        - message: r
        - message: r
          text: a
          instruction: b
        - message: r
          text: |
            two
            lines
      """)
    #expect(paths(of: "content_required", in: yaml) == ["steps[0]"])
    #expect(paths(of: "multiple_contents", in: yaml) == ["steps[1]"])
    #expect(paths(of: "multiline_text", in: yaml) == ["steps[2].text"])
  }

  @Test
  func launchNeedsAPrompt() {
    #expect(paths(of: "missing_key", in: document("steps: [{launch: r}]")) == ["steps[0].prompt"])
  }

  @Test
  func runParsesItsOptionsAndDefaults() throws {
    let yaml = document(
      """
      steps:
        - run: swift test
        - run: ${{ codans.cli }} tree
          working-directory: sub
          env: {FOO: "${{ inputs.x }}", BAR: plain}
          timeout-minutes: 3
          continue-on-error: true
          in: me
      """)
    let definition = try #require(parse(yaml).definition)
    guard case .run(let plain) = definition.steps[0].verb, case .run(let full) = definition.steps[1].verb else {
      Issue.record("expected run steps")
      return
    }
    #expect(plain.timeoutMinutes == WorkflowRunCommand.defaultTimeoutMinutes)
    #expect(plain.continueOnError == false)
    #expect(plain.inRole == nil)
    #expect(plain.env.isEmpty)
    #expect(full.workingDirectory?.source == "sub")
    #expect(full.env.keys.sorted() == ["BAR", "FOO"])
    #expect(full.env["FOO"]?.soleExpression?.source == " inputs.x ")
    #expect(full.timeoutMinutes == 3)
    #expect(full.continueOnError)
    #expect(full.inRole == "me")
  }

  @Test
  func integerOptionsMustBePositive() {
    let yaml = document(
      """
      steps:
        - run: x
          timeout-minutes: 0
        - wait: r
          timeout-minutes: "5"
        - while: true
          max-iterations: -1
          steps: [{notify: x}]
        - launch: r
          prompt: p
          expect: {timeout-minutes: 1.5}
      """)
    #expect(paths(of: "invalid_value", in: yaml) == ["steps[0].timeout-minutes", "steps[2].max-iterations"])
    #expect(paths(of: "invalid_type", in: yaml) == ["steps[1].timeout-minutes", "steps[3].expect.timeout-minutes"])
  }

  @Test
  func waitParsesItsCondition() throws {
    let yaml = document(
      """
      steps:
        - wait: r
        - wait: r
          until: exit
          timeout-minutes: 2
        - wait: r
          until: done
      """)
    let result = parse(yaml)
    #expect(result.diagnostics.map(\.path) == ["steps[2].until"])
    #expect(result.diagnostics.map(\.code) == ["invalid_value"])
    let ok = try #require(
      parse(document("steps:\n  - wait: r\n  - {wait: r, until: exit, timeout-minutes: 2}")).definition)
    #expect(ok.steps[0].verb == .wait(role: "r", until: .idle, timeoutMinutes: nil))
    #expect(ok.steps[1].verb == .wait(role: "r", until: .exit, timeoutMinutes: 2))
  }

  @Test
  func setValuesAreTemplatesAndLiteralsBecomeText() throws {
    let yaml = document(
      """
      steps:
        - set: {n: 5, flag: true, expr: "${{ state.n + 1 }}", mixed: "round ${{ state.n }}"}
      """)
    let definition = try #require(parse(yaml).definition)
    guard case .set(let assignments) = definition.steps[0].verb else {
      Issue.record("expected a set step")
      return
    }
    #expect(assignments.map(\.name) == ["n", "flag", "expr", "mixed"])
    #expect(assignments[0].value == .literal("5"))
    #expect(assignments[1].value == .literal("true"))
    #expect(assignments[2].value.soleExpression != nil)
    #expect(assignments[3].value.soleExpression == nil)
    #expect(assignments[3].value.isStatic == false)
  }

  @Test
  func setMustAssignSomething() {
    #expect(paths(of: "empty_collection", in: document("steps: [{set: {}}]")) == ["steps[0].set"])
    #expect(paths(of: "invalid_type", in: document("steps: [{set: [a]}]")) == ["steps[0].set"])
    #expect(paths(of: "invalid_type", in: document("steps: [{set: {a: [1]}}]")) == ["steps[0].set.a"])
  }

  @Test
  func whileNeedsANonEmptyBody() {
    #expect(paths(of: "missing_key", in: document("steps: [{while: true}]")) == ["steps[0].steps"])
    #expect(paths(of: "empty_collection", in: document("steps: [{while: true, steps: []}]")) == ["steps[0].steps"])
  }

  @Test
  func breakAndContinueMustBeLiterallyTrue() throws {
    #expect(paths(of: "invalid_value", in: document("steps: [{break: false}]")) == ["steps[0].break"])
    #expect(paths(of: "invalid_type", in: document("steps: [{continue: yes-please}]")) == ["steps[0].continue"])
    let ok = try #require(parse(document("steps: [{break: true}, {continue: true}]")).definition)
    #expect(ok.steps.map(\.verb) == [.breakLoop, .continueLoop])
  }

  // MARK: - Expectations

  @Test
  func expectationDefaultsAndOverrides() throws {
    let yaml = document(
      """
      steps:
        - id: ask
          message: r
          text: hi
          expect: {}
        - message: r
          text: hi
          expect:
            delivery: answer
            format: json
            sections: ["## A", "## B"]
            verdicts: [yes, no, maybe]
            timeout-minutes: 30
            on-timeout: skip
            strict: true
      """)
    let definition = try #require(parse(yaml).definition)
    #expect(definition.steps[0].expectation == WorkflowExpectation(delivery: "ask"))
    #expect(
      definition.steps[1].expectation
        == WorkflowExpectation(
          delivery: "answer", format: .json, sections: ["## A", "## B"], verdicts: ["yes", "no", "maybe"],
          timeoutMinutes: 30, onTimeout: .skip, strict: true))
  }

  @Test
  func expectationConstraints() {
    let yaml = document(
      """
      steps:
        - message: r
          text: hi
          expect: {verdicts: [only]}
        - message: r
          text: hi
          expect: {verdicts: [a, b, c, d, e]}
        - message: r
          text: hi
          expect: {on-timeout: cancel}
        - message: r
          text: hi
          expect: {verdicts: [Clean, issues], format: html, deliver: x}
      """)
    #expect(paths(of: "verdict_count", in: yaml) == ["steps[0].expect.verdicts", "steps[1].expect.verdicts"])
    #expect(paths(of: "on_timeout_without_timeout", in: yaml) == ["steps[2].expect.on-timeout"])
    #expect(paths(of: "invalid_identifier", in: yaml) == ["steps[3].expect.verdicts[0]"])
    #expect(paths(of: "invalid_value", in: yaml) == ["steps[3].expect.format"])
    #expect(paths(of: "unknown_key", in: yaml) == ["steps[3].expect.deliver"])
  }

  @Test
  func errorsElsewhereDoNotStopTheRestOfTheFileFromBeingChecked() {
    let yaml = document(
      """
      inputs:
        x: {type: nope}
      roles:
        r: {source: current, profile: p}
      steps:
        - notify: a
          extra: 1
        - launch: r
      """)
    #expect(codes(in: yaml) == ["invalid_value", "key_not_allowed", "unknown_key", "missing_key"])
  }
}
