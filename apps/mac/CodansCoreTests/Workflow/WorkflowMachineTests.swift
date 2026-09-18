import Foundation
import Testing

@testable import CodansCore

/// The executable specification of the run machine: feed events, assert
/// effect sequences. The `review-loop` workflow from the design doc is
/// driven through a whole fix / re-review iteration; the rest pins the
/// attention table, the delivery protocol, and the control flow.
struct WorkflowMachineTests {
  // MARK: - Fixtures

  private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  private static let authorPane = PaneID(raw: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
  private static let reviewerPane = PaneID(raw: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
  private static let reviewerProfile = UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!
  private static let runID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D0")!
  private static let runDirectory = "/w/.codans/workflow-runs/run"

  private static func template(_ source: String) throws -> WorkflowTemplate {
    try WorkflowTemplate.parse(source)
  }

  private static func expression(_ source: String) throws -> WorkflowExpression {
    try WorkflowExpression.parse(source)
  }

  private static let reviewExpectation = WorkflowExpectation(
    delivery: "review", sections: ["## Findings"], verdicts: ["clean", "issues"])

  /// The design doc's `review-loop`, built with the Swift initializers.
  private static func reviewLoop() throws -> WorkflowDefinition {
    WorkflowDefinition(
      id: "review-loop",
      name: "Review Loop",
      inputs: [
        WorkflowInput(name: "max-rounds", kind: .number, defaultValue: 3),
        WorkflowInput(name: "focus", kind: .string, defaultValue: ""),
      ],
      roles: [
        WorkflowRole(name: "author", source: .current),
        WorkflowRole(name: "reviewer", source: .launch, placement: .split, direction: .right, background: true),
      ],
      state: [
        WorkflowStateVariable(name: "round", initial: 0),
        WorkflowStateVariable(name: "verdict", initial: "issues"),
      ],
      steps: [
        WorkflowStep(
          id: "kickoff", name: "Launch the reviewer",
          verb: .launch(
            role: "reviewer",
            prompt: try template("Review the uncommitted changes in this worktree. ${{ inputs.focus }}"),
            expect: reviewExpectation)),
        WorkflowStep(
          id: "seed", hasExplicitID: false,
          verb: .set([
            WorkflowAssignment(name: "verdict", value: try template("${{ deliveries.review.verdict }}"))
          ])),
        WorkflowStep(
          id: "fix-loop", name: "Fix and re-review",
          verb: .loop(
            condition: try expression("state.verdict == 'issues' && state.round < inputs.max-rounds"),
            maxIterations: 10,
            steps: [
              WorkflowStep(
                id: "bump", hasExplicitID: false,
                verb: .set([WorkflowAssignment(name: "round", value: try template("${{ state.round + 1 }}"))])),
              WorkflowStep(
                id: "fix", name: "Ask the author to address the review",
                verb: .message(
                  role: "author",
                  content: .instruction(
                    try template(
                      "Address the review at ${{ deliveries.review.path }}. Deliver a short summary when done.")),
                  expect: WorkflowExpectation(delivery: "fixes"))),
              WorkflowStep(
                id: "re-review", name: "Re-review",
                verb: .message(
                  role: "reviewer",
                  content: .text(try template("Re-review after the fixes described in ${{ deliveries.fixes.path }}.")),
                  expect: reviewExpectation)),
              WorkflowStep(
                id: "record", hasExplicitID: false,
                verb: .set([
                  WorkflowAssignment(name: "verdict", value: try template("${{ deliveries.review.verdict }}"))
                ])),
            ])),
        WorkflowStep(
          id: "clean-notify", hasExplicitID: false,
          condition: try expression("state.verdict == 'clean'"),
          verb: .notify(try template("Review clean after ${{ state.round }} round(s)."))),
        WorkflowStep(
          id: "issues-notify", hasExplicitID: false,
          condition: try expression("state.verdict != 'clean'"),
          verb: .notify(
            try template("Still has issues after ${{ state.round }} round(s); see ${{ deliveries.review.path }}."))),
      ]
    )
  }

  private static func configuration(
    _ definition: WorkflowDefinition,
    bindings: [String: WorkflowRoleBinding]? = nil,
    inputs: [String: WorkflowValue] = ["max-rounds": 3, "focus": ""],
    initiatorPaneID: PaneID? = nil
  ) -> WorkflowRunConfiguration {
    WorkflowRunConfiguration(
      id: runID,
      definition: definition,
      source: WorkflowRunSource(
        projectID: ProjectID(), worktreeID: WorktreeID(), worktreePath: "/w", worktreeName: "w", branch: "main"),
      bindings: bindings ?? [
        "author": .current(paneID: authorPane),
        "reviewer": .launch(
          profileID: reviewerProfile, profileName: "Reviewer", agent: .codex, paneID: nil),
      ],
      inputs: inputs,
      runDirectory: runDirectory,
      cliCommand: "codans",
      initiatorPaneID: initiatorPaneID,
      startedAt: epoch
    )
  }

  /// Drives one machine with a deterministic clock and token mint.
  private final class Driver {
    var machine: WorkflowMachine
    var now = WorkflowMachineTests.epoch
    private var minted = 0

    init(_ configuration: WorkflowRunConfiguration) {
      var minted = 0
      let started = WorkflowMachine.start(configuration, now: now) {
        minted += 1
        return "tok-\(minted)"
      }
      machine = started.machine
      self.minted = minted
      startEffects = started.effects
      selfInitiated = started.selfInitiated
    }

    let startEffects: [WorkflowEffect]
    let selfInitiated: WorkflowSelfInitiatedTask?

    var run: WorkflowRunState { machine.run }

    private func mint() -> String {
      minted += 1
      return "tok-\(minted)"
    }

    @discardableResult
    func apply(_ event: WorkflowRunEvent) -> [WorkflowEffect] {
      let mint = mint
      return machine.apply(event, now: now, makeToken: mint)
    }

    func deliver(_ ordinal: Int, token: String?, body: String, verdict: String? = nil, allowManual: Bool = false)
      -> (outcome: WorkflowDeliveryOutcome, effects: [WorkflowEffect])
    {
      machine.deliver(ordinal: ordinal, token: token, allowManual: allowManual, body: body, verdict: verdict, now: now)
    }

    func user(_ action: WorkflowUserAction, verdict: String? = nil) -> [WorkflowEffect] {
      apply(.user(action, verdict: verdict))
    }
  }

  private static func command(_ token: String, verdicts: [String]? = nil) -> String {
    WorkflowCompletionCommand.render(cli: "codans", token: token, verdicts: verdicts)
  }

  /// Drives `review-loop` up to the point where the reviewer's first
  /// delivery has been persisted (the loop body's first message step is
  /// waiting for the author).
  private static func afterKickoff(verdict: String = "issues") throws -> Driver {
    let driver = Driver(configuration(try reviewLoop()))
    driver.apply(.launched(ordinal: 1, paneID: reviewerPane))
    _ = driver.deliver(1, token: "tok-1", body: "## Findings\n- nit\n", verdict: verdict)
    driver.apply(.deliveryPersisted(ordinal: 1, path: "/w/d/review.1.md", latestPath: "/w/d/review.md"))
    return driver
  }

  // MARK: - review-loop, one full iteration

  @Test
  func startLaunchesTheReviewerWithTokenInEnvironment() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    #expect(driver.startEffects.count == 3)
    #expect(driver.startEffects[0] == .openActivation(ordinal: 1, paneID: nil, token: "tok-1"))
    guard case .launch(let request) = driver.startEffects[1] else {
      Issue.record("expected a launch effect, got \(driver.startEffects[1])")
      return
    }
    #expect(request.role == "reviewer")
    #expect(request.ordinal == 1)
    #expect(request.profileID == Self.reviewerProfile)
    #expect(request.placement == .split)
    #expect(request.direction == .right)
    #expect(request.background)
    #expect(request.anchorPaneID == Self.authorPane)
    #expect(request.environment["CODANS_WORKFLOW_TOKEN"] == "tok-1")
    #expect(request.environment["CODANS_WORKFLOW_RUN"] == Self.runID.uuidString)
    #expect(request.environment["CODANS_WORKFLOW_ROLE"] == "reviewer")
    #expect(request.prompt.hasPrefix("Review the uncommitted changes in this worktree. "))
    #expect(request.prompt.contains(Self.command("tok-1", verdicts: ["clean", "issues"])))
    #expect(driver.startEffects[2] == .persistRecord)
    #expect(driver.run.phase == .launching(ordinal: 1))
    #expect(driver.selfInitiated == nil)
    #expect(driver.run.log.first?.hasSuffix("start: Review Loop (review-loop)") == true)
  }

  @Test
  func launchedArmsTheWatchdogAndBindsThePane() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    let effects = driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    #expect(
      effects == [
        .openActivation(ordinal: 1, paneID: Self.reviewerPane, token: "tok-1"),
        .armWatchdog(ordinal: 1, idleGraceSeconds: 180, deadline: nil),
        .persistRecord,
      ])
    #expect(driver.run.phase == .waitingForDelivery(ordinal: 1))
    #expect(driver.run.bindings["reviewer"]?.paneID == Self.reviewerPane)
    #expect(driver.run.activations[1]?.paneID == Self.reviewerPane)
  }

  @Test
  func acceptedDeliveryIsPersistedThenTheLoopStarts() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    let delivered = driver.deliver(1, token: "tok-1", body: "## Findings\n- nit\n", verdict: "issues")
    #expect(delivered.outcome == .accepted)
    #expect(
      delivered.effects == [
        .persistDelivery(ordinal: 1, name: "review", body: "## Findings\n- nit", verdict: "issues", provisional: false),
        .persistRecord,
      ])
    #expect(driver.run.activations[1]?.state == .persisting)

    let effects = driver.apply(
      .deliveryPersisted(ordinal: 1, path: "/w/d/review.1.md", latestPath: "/w/d/review.md"))
    #expect(
      effects == [
        .disarmWatchdog(ordinal: 1),
        .revokeActivation(ordinal: 1),
        .openActivation(ordinal: 2, paneID: Self.authorPane, token: "tok-2"),
        .awaitRole(role: "author", paneID: Self.authorPane, until: .idle, timeoutMinutes: nil),
        .persistRecord,
      ])
    #expect(driver.run.steps["kickoff"]?.outcome == .success)
    #expect(driver.run.deliveries["review"]?.verdict == "issues")
    #expect(driver.run.state["round"] == 1)
    #expect(driver.run.loopIteration == 1)
    #expect(driver.run.currentStepID == "fix")
    #expect(driver.run.phase == .waitingForRole(role: "author", ordinal: 2))
  }

  @Test
  func idleAuthorGetsTheInstructionPointerWithCompletionCommand() throws {
    let driver = try Self.afterKickoff()
    let effects = driver.apply(.roleIdle(role: "author"))
    let instructionPath = "\(Self.runDirectory)/instructions/fix.2.md"
    #expect(
      effects == [
        .materializeInstruction(
          ordinal: 2, stepID: "fix",
          text: "Address the review at /w/d/review.1.md. Deliver a short summary when done."),
        .inject(
          paneID: Self.authorPane, ordinal: 2,
          line: "[codans] Read and follow \(instructionPath) — finish with: \(Self.command("tok-2"))"),
        .persistRecord,
      ])
    #expect(driver.run.phase == .injecting(ordinal: 2))
    #expect(
      driver.apply(.injected(ordinal: 2)) == [
        .armWatchdog(ordinal: 2, idleGraceSeconds: 180, deadline: nil), .persistRecord,
      ])
    #expect(driver.run.phase == .waitingForDelivery(ordinal: 2))
  }

  @Test
  func fullIterationEndsCleanWithANotification() throws {
    let driver = try Self.afterKickoff()
    driver.apply(.roleIdle(role: "author"))
    driver.apply(.injected(ordinal: 2))
    #expect(driver.deliver(2, token: "tok-2", body: "Fixed the nit.").outcome == .accepted)
    let afterFixes = driver.apply(
      .deliveryPersisted(ordinal: 2, path: "/w/d/fixes.2.md", latestPath: "/w/d/fixes.md"))
    #expect(
      afterFixes == [
        .disarmWatchdog(ordinal: 2),
        .revokeActivation(ordinal: 2),
        .openActivation(ordinal: 3, paneID: Self.reviewerPane, token: "tok-3"),
        .awaitRole(role: "reviewer", paneID: Self.reviewerPane, until: .idle, timeoutMinutes: nil),
        .persistRecord,
      ])
    #expect(
      driver.apply(.roleIdle(role: "reviewer")) == [
        .inject(
          paneID: Self.reviewerPane, ordinal: 3,
          line: "Re-review after the fixes described in /w/d/fixes.2.md. — finish with: "
            + Self.command("tok-3", verdicts: ["clean", "issues"])),
        .persistRecord,
      ])
    driver.apply(.injected(ordinal: 3))
    #expect(driver.deliver(3, token: "tok-3", body: "## Findings\nNone.\n", verdict: "clean").outcome == .accepted)
    let final = driver.apply(
      .deliveryPersisted(ordinal: 3, path: "/w/d/review.3.md", latestPath: "/w/d/review.md"))
    #expect(
      final == [
        .disarmWatchdog(ordinal: 3),
        .revokeActivation(ordinal: 3),
        .notify(title: "Workflow · Review Loop", body: "Review clean after 1 round(s)."),
        .persistRecord,
        .finished(.completed),
      ])
    #expect(driver.run.status == .completed)
    #expect(driver.run.phase == .finished)
    #expect(driver.run.finishedAt == Self.epoch)
    #expect(driver.run.state["verdict"] == "clean")
    #expect(driver.run.steps["fix-loop"]?.outcome == .success)
    #expect(driver.run.steps["clean-notify"]?.outcome == .success)
    #expect(driver.run.steps["issues-notify"]?.outcome == .skipped)
    #expect(driver.run.deliveries["review"]?.ordinal == 3)
  }

  // MARK: - Start variants

  @Test
  func selfInitiatedStartHandsTheTaskBackInsteadOfTyping() throws {
    let definition = WorkflowDefinition(
      id: "handoff", name: "Handoff",
      roles: [WorkflowRole(name: "author", source: .current)],
      steps: [
        WorkflowStep(
          id: "brief",
          verb: .message(
            role: "author", content: .instruction(try Self.template("Write a briefing.")),
            expect: WorkflowExpectation(delivery: "briefing")))
      ])
    let driver = Driver(
      Self.configuration(
        definition, bindings: ["author": .current(paneID: Self.authorPane)], inputs: [:],
        initiatorPaneID: Self.authorPane))
    let task = try #require(driver.selfInitiated)
    #expect(task.stepID == "brief")
    #expect(task.ordinal == 1)
    #expect(task.instructionPath == "\(Self.runDirectory)/instructions/brief.1.md")
    #expect(task.completionCommand == Self.command("tok-1"))
    #expect(task.line.hasPrefix("[codans] Read and follow "))
    #expect(
      driver.startEffects == [
        .openActivation(ordinal: 1, paneID: Self.authorPane, token: "tok-1"),
        .materializeInstruction(ordinal: 1, stepID: "brief", text: "Write a briefing."),
        .armWatchdog(ordinal: 1, idleGraceSeconds: 180, deadline: nil),
        .persistRecord,
      ])
    #expect(driver.run.phase == .waitingForDelivery(ordinal: 1))
  }

  @Test
  func aDifferentInitiatorIsNotSelfInitiated() throws {
    let definition = WorkflowDefinition(
      id: "handoff", name: "Handoff",
      roles: [WorkflowRole(name: "author", source: .current)],
      steps: [
        WorkflowStep(
          id: "brief",
          verb: .message(role: "author", content: .text(try Self.template("Say hi.")), expect: nil))
      ])
    let driver = Driver(
      Self.configuration(
        definition, bindings: ["author": .current(paneID: Self.authorPane)], inputs: [:],
        initiatorPaneID: Self.reviewerPane))
    #expect(driver.selfInitiated == nil)
    #expect(
      driver.startEffects == [
        .awaitRole(role: "author", paneID: Self.authorPane, until: .idle, timeoutMinutes: nil), .persistRecord,
      ])
  }

  @Test
  func falseGuardSkipsTheStep() throws {
    let definition = WorkflowDefinition(
      id: "guarded", name: "Guarded",
      steps: [
        WorkflowStep(
          id: "never", condition: try Self.expression("false"), verb: .notify(try Self.template("no"))),
        WorkflowStep(id: "always", verb: .notify(try Self.template("yes"))),
      ])
    let driver = Driver(Self.configuration(definition, bindings: [:], inputs: [:]))
    #expect(
      driver.startEffects == [
        .notify(title: "Workflow · Guarded", body: "yes"), .persistRecord, .finished(.completed),
      ])
    #expect(driver.run.steps["never"]?.outcome == .skipped)
    #expect(driver.run.steps["always"]?.outcome == .success)
  }

  @Test
  func stepsSkippedAtStartAreRecordedAsSkipped() throws {
    let definition = WorkflowDefinition(
      id: "guarded", name: "Guarded",
      steps: [WorkflowStep(id: "only", verb: .notify(try Self.template("yes")))])
    var configuration = Self.configuration(definition, bindings: [:], inputs: [:])
    configuration.skippedSteps = ["only"]
    let driver = Driver(configuration)
    #expect(driver.startEffects == [.persistRecord, .finished(.completed)])
    #expect(driver.run.steps["only"]?.outcome == .skipped)
  }

  // MARK: - Loops

  @Test
  func loopStopsAtItsIterationCap() throws {
    let definition = WorkflowDefinition(
      id: "spin", name: "Spin",
      state: [WorkflowStateVariable(name: "n", initial: 0)],
      steps: [
        WorkflowStep(
          id: "loop",
          verb: .loop(
            condition: try Self.expression("true"), maxIterations: 2,
            steps: [
              WorkflowStep(
                id: "inc", verb: .set([WorkflowAssignment(name: "n", value: try Self.template("${{ state.n + 1 }}"))]))
            ]))
      ])
    let driver = Driver(Self.configuration(definition, bindings: [:], inputs: [:]))
    #expect(driver.run.status == .iterationLimitReached(loop: "loop"))
    #expect(driver.run.state["n"] == 2)
    #expect(driver.startEffects.last == .finished(.iterationLimitReached(loop: "loop")))
  }

  @Test
  func breakLeavesTheLoopAndContinueRestartsIt() throws {
    let definition = WorkflowDefinition(
      id: "flow", name: "Flow",
      state: [WorkflowStateVariable(name: "n", initial: 0)],
      steps: [
        WorkflowStep(
          id: "loop",
          verb: .loop(
            condition: try Self.expression("true"), maxIterations: 10,
            steps: [
              WorkflowStep(
                id: "inc", verb: .set([WorkflowAssignment(name: "n", value: try Self.template("${{ state.n + 1 }}"))])),
              WorkflowStep(id: "again", condition: try Self.expression("state.n < 3"), verb: .continueLoop),
              WorkflowStep(id: "out", verb: .breakLoop),
              WorkflowStep(id: "unreached", verb: .notify(try Self.template("never"))),
            ])),
        WorkflowStep(id: "done", verb: .notify(try Self.template("n=${{ state.n }}"))),
      ])
    let driver = Driver(Self.configuration(definition, bindings: [:], inputs: [:]))
    #expect(driver.run.status == .completed)
    #expect(driver.startEffects.contains(.notify(title: "Workflow · Flow", body: "n=3")))
    #expect(driver.run.steps["unreached"] == nil)
    #expect(driver.run.steps["loop"]?.outcome == .success)
  }

  @Test
  func uncappedLoopWithoutEffectsIsRefused() throws {
    let definition = WorkflowDefinition(
      id: "spin", name: "Spin",
      state: [WorkflowStateVariable(name: "n", initial: 0)],
      steps: [
        WorkflowStep(
          id: "loop",
          verb: .loop(
            condition: try Self.expression("true"), maxIterations: nil,
            steps: [
              WorkflowStep(
                id: "inc", verb: .set([WorkflowAssignment(name: "n", value: try Self.template("${{ state.n + 1 }}"))]))
            ]))
      ])
    let driver = Driver(Self.configuration(definition, bindings: [:], inputs: [:]))
    guard case .failed(let step, let reason) = driver.run.status else {
      Issue.record("expected failed, got \(driver.run.status)")
      return
    }
    #expect(step == "loop")
    #expect(reason.contains("max-iterations"))
  }

  @Test
  func expressionErrorsFailTheRun() throws {
    let definition = WorkflowDefinition(
      id: "bad", name: "Bad",
      steps: [WorkflowStep(id: "n", verb: .notify(try Self.template("${{ deliveries.nothing.path }}")))])
    let driver = Driver(Self.configuration(definition, bindings: [:], inputs: [:]))
    #expect(driver.run.status == .failed(step: "n", reason: "`deliveries.nothing.path` is not defined"))
    #expect(driver.startEffects == [.persistRecord, .finished(driver.run.status)])
  }

  // MARK: - Delivery protocol

  @Test
  func wrongTokenIsRejectedWithoutSideEffects() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    let before = driver.run
    let result = driver.deliver(1, token: "nope", body: "## Findings\nx", verdict: "clean")
    guard case .rejected(let code, _) = result.outcome else {
      Issue.record("expected rejection, got \(result.outcome)")
      return
    }
    #expect(code == "TOKEN_INVALID")
    #expect(result.effects.isEmpty)
    var after = driver.run
    after.log = before.log
    #expect(after == before)
  }

  @Test
  func missingTokenNeedsManualAddressing() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    guard case .rejected(let code, _) = driver.deliver(1, token: nil, body: "## Findings\nx", verdict: "clean").outcome
    else {
      Issue.record("expected rejection")
      return
    }
    #expect(code == "TOKEN_REQUIRED")
    let manual = driver.deliver(1, token: nil, body: "## Findings\nx", verdict: "clean", allowManual: true)
    #expect(manual.outcome == .accepted)
  }

  @Test
  func unknownOrdinalIsNotExpecting() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    guard case .rejected(let code, _) = driver.deliver(2, token: "tok-1", body: "x").outcome else {
      Issue.record("expected rejection")
      return
    }
    #expect(code == "STEP_NOT_EXPECTING")
    // A finished activation no longer accepts either.
    _ = driver.deliver(1, token: "tok-1", body: "## Findings\nx", verdict: "clean")
    guard case .rejected(let again, _) = driver.deliver(1, token: "tok-1", body: "x").outcome else {
      Issue.record("expected rejection")
      return
    }
    #expect(again == "STEP_NOT_EXPECTING")
  }

  @Test
  func unknownVerdictAndEmptyBodyAreRejected() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    guard
      case .rejected(let code, _) = driver.deliver(1, token: "tok-1", body: "## Findings\nx", verdict: "meh").outcome
    else {
      Issue.record("expected rejection")
      return
    }
    #expect(code == "OUTPUT_INVALID")
    guard case .rejected(let empty, _) = driver.deliver(1, token: "tok-1", body: "  \n", verdict: "clean").outcome
    else {
      Issue.record("expected rejection")
      return
    }
    #expect(empty == "OUTPUT_INVALID")
  }

  @Test
  func provisionalDeliveryAsksTheUserAndAskAgainReinjects() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    let delivered = driver.deliver(1, token: "tok-1", body: "Looks fine.")
    #expect(
      delivered.outcome
        == .provisional(issues: [
          "missing section(s): ## Findings", "a verdict is required: --verdict clean|issues",
        ]))
    #expect(
      delivered.effects.first
        == .persistDelivery(ordinal: 1, name: "review", body: "Looks fine.", verdict: nil, provisional: true))

    let effects = driver.apply(
      .deliveryPersisted(ordinal: 1, path: "/w/d/review.1.md", latestPath: "/w/d/review.md"))
    #expect(effects == [.disarmWatchdog(ordinal: 1), .persistRecord])
    let attention = try #require(driver.run.status.attention)
    #expect(attention.reason == .provisionalDelivery)
    #expect(attention.stepID == "kickoff")
    #expect(attention.role == "reviewer")
    #expect(attention.ordinal == 1)
    #expect(attention.actions == [.accept, .acceptWithVerdict, .askAgain, .skip, .cancel])
    #expect(attention.issues.count == 2)
    #expect(driver.run.activations[1]?.state == .provisional)
    #expect(driver.run.deliveries["review"]?.isProvisional == true)

    #expect(
      driver.user(.askAgain) == [
        .awaitRole(role: "reviewer", paneID: Self.reviewerPane, until: .idle, timeoutMinutes: nil), .persistRecord,
      ])
    #expect(driver.run.status == .running)
    #expect(driver.run.activations[1]?.state == .waiting)
    let injected = driver.apply(.roleIdle(role: "reviewer"))
    guard case .inject(let pane, let ordinal, let line) = injected.first else {
      Issue.record("expected an inject, got \(injected)")
      return
    }
    #expect(pane == Self.reviewerPane)
    #expect(ordinal == 1)
    #expect(line.contains("missing section(s): ## Findings"))
    #expect(line.hasSuffix(Self.command("tok-1", verdicts: ["clean", "issues"])))
    driver.apply(.injected(ordinal: 1))
    #expect(driver.run.phase == .waitingForDelivery(ordinal: 1))

    #expect(driver.deliver(1, token: "tok-1", body: "## Findings\n- nit", verdict: "issues").outcome == .accepted)
    driver.apply(.deliveryPersisted(ordinal: 1, path: "/w/d/review.1.md", latestPath: "/w/d/review.md"))
    #expect(driver.run.deliveries["review"]?.isProvisional == false)
    #expect(driver.run.currentStepID == "fix")
  }

  @Test
  func acceptWithVerdictFillsTheMissingVerdict() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    _ = driver.deliver(1, token: "tok-1", body: "## Findings\nNone.")
    driver.apply(.deliveryPersisted(ordinal: 1, path: "/w/d/review.1.md", latestPath: "/w/d/review.md"))
    #expect(driver.run.status.attention?.actions.contains(.acceptWithVerdict) == true)
    // An undeclared verdict is ignored; the run stays in attention.
    #expect(driver.user(.acceptWithVerdict, verdict: "maybe").isEmpty)
    #expect(driver.run.status.attention != nil)
    let effects = driver.user(.acceptWithVerdict, verdict: "clean")
    #expect(effects.contains(.notify(title: "Workflow · Review Loop", body: "Review clean after 0 round(s).")))
    #expect(driver.run.status == .completed)
    #expect(driver.run.deliveries["review"]?.verdict == "clean")
    #expect(driver.run.deliveries["review"]?.isProvisional == false)
  }

  @Test
  func strictExpectationRejectsInsteadOfHolding() throws {
    var definition = try Self.reviewLoop()
    var strict = Self.reviewExpectation
    strict.strict = true
    definition.steps[0].verb = .launch(role: "reviewer", prompt: try Self.template("Review."), expect: strict)
    let driver = Driver(Self.configuration(definition))
    driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    guard case .rejected(let code, _) = driver.deliver(1, token: "tok-1", body: "## Findings\nx").outcome else {
      Issue.record("expected rejection")
      return
    }
    #expect(code == "VERDICT_REQUIRED")
    #expect(driver.run.activations[1]?.state == .waiting)
  }

  // MARK: - Skip and cancel

  @Test
  func skipConsequenceNamesTheFirstDependentStep() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    // Nothing delivered yet: the loop body's first message needs the review.
    #expect(driver.machine.skipConsequence(forDelivery: "review") == "seed")
    #expect(driver.machine.skipConsequence(forDelivery: "unrelated") == nil)
  }

  @Test
  func skippingARequiredDeliveryEndsTheRunAsSkipped() throws {
    let driver = try Self.afterKickoff()
    driver.apply(.roleBlocked(role: "author"))
    let attention = try #require(driver.run.status.attention)
    #expect(attention.reason == .roleBlocked)
    #expect(attention.actions == [.focusPane, .keepWaiting, .skip, .cancel])
    #expect(driver.user(.focusPane).isEmpty)
    let effects = driver.user(.skip)
    #expect(effects.contains(.revokeActivation(ordinal: 2)))
    #expect(effects.last == .finished(.skipped(step: "fix", dependent: "re-review")))
    #expect(driver.run.steps["fix"]?.outcome == .skipped)
    #expect(driver.run.activations[2]?.state == .skipped)
  }

  @Test
  func skippingAnOptionalDeliveryMovesOn() throws {
    // The reviewer already delivered once, so skipping a re-review leaves
    // the earlier review in place for every later reference.
    let driver = try Self.afterKickoff()
    driver.apply(.roleIdle(role: "author"))
    driver.apply(.injected(ordinal: 2))
    _ = driver.deliver(2, token: "tok-2", body: "Fixed.")
    driver.apply(.deliveryPersisted(ordinal: 2, path: "/w/d/fixes.2.md", latestPath: "/w/d/fixes.md"))
    #expect(driver.run.currentStepID == "re-review")
    #expect(driver.machine.skipConsequence(forDelivery: "review") == nil)
    driver.apply(.roleGone(role: "reviewer"))
    #expect(driver.run.status.attention?.actions == [.relaunch, .skip, .cancel])
    let effects = driver.user(.skip)
    #expect(driver.run.steps["re-review"]?.outcome == .skipped)
    // verdict stays "issues" from round one, so the loop goes around again.
    #expect(driver.run.state["round"] == 2)
    #expect(driver.run.currentStepID == "fix")
    #expect(effects.contains(.openActivation(ordinal: 4, paneID: Self.authorPane, token: "tok-4")))
  }

  @Test
  func cancelRevokesTheActivationAndEndsTheRun() throws {
    let driver = try Self.afterKickoff()
    let effects = driver.user(.cancel)
    #expect(
      effects == [
        .cancelRoleWait(role: "author"), .revokeActivation(ordinal: 2), .persistRecord, .finished(.cancelled),
      ])
    #expect(driver.run.status == .cancelled)
    #expect(driver.run.steps["fix"]?.outcome == .failure)
    #expect(driver.run.activations[2]?.state == .revoked)
    // Nothing moves after the end.
    #expect(driver.apply(.roleIdle(role: "author")).isEmpty)
  }

  // MARK: - Watchdog

  @Test
  func watchdogNudgesOnceThenAsksForAttention() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    let nudge = driver.apply(.watchdog(ordinal: 1, .idleGraceElapsed))
    #expect(
      nudge == [
        .inject(
          paneID: Self.reviewerPane, ordinal: 1,
          line: "[codans] When your work is complete, deliver it with: "
            + Self.command("tok-1", verdicts: ["clean", "issues"])),
        .armWatchdog(ordinal: 1, idleGraceSeconds: 180, deadline: nil),
        .persistRecord,
      ])
    #expect(driver.run.activations[1]?.nudged == true)
    // The nudge's own `injected` is not a phase change.
    #expect(driver.apply(.injected(ordinal: 1)).isEmpty)
    #expect(driver.run.phase == .waitingForDelivery(ordinal: 1))

    let escalation = driver.apply(.watchdog(ordinal: 1, .idleGraceElapsed))
    #expect(escalation == [.disarmWatchdog(ordinal: 1), .persistRecord])
    let attention = try #require(driver.run.status.attention)
    #expect(attention.reason == .noDeliveryAfterIdle)
    #expect(attention.actions == [.keepWaiting, .askAgain, .skip, .cancel])
    #expect(
      driver.user(.keepWaiting) == [.armWatchdog(ordinal: 1, idleGraceSeconds: 180, deadline: nil), .persistRecord])
    #expect(driver.run.status == .running)
  }

  @Test
  func deadlineFollowsTheTimeoutPolicy() throws {
    var definition = try Self.reviewLoop()
    var timed = Self.reviewExpectation
    timed.timeoutMinutes = 30
    definition.steps[0].verb = .launch(role: "reviewer", prompt: try Self.template("Review."), expect: timed)
    let driver = Driver(Self.configuration(definition))
    let deadline = Self.epoch.addingTimeInterval(1800)
    #expect(
      driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane)).contains(
        .armWatchdog(ordinal: 1, idleGraceSeconds: 180, deadline: deadline)))
    driver.apply(.watchdog(ordinal: 1, .deadlineReached))
    let attention = try #require(driver.run.status.attention)
    #expect(attention.reason == .deliveryTimeout)
    #expect(attention.actions == [.keepWaiting, .skip, .cancel])
    driver.now = deadline
    #expect(
      driver.user(.keepWaiting).first
        == .armWatchdog(ordinal: 1, idleGraceSeconds: 180, deadline: deadline.addingTimeInterval(1800)))
  }

  @Test
  func staleOrdinalsAreIgnored() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    let before = driver.run
    #expect(driver.apply(.watchdog(ordinal: 99, .idleGraceElapsed)).isEmpty)
    #expect(driver.apply(.injected(ordinal: 7)).isEmpty)
    #expect(driver.apply(.launched(ordinal: 3, paneID: Self.authorPane)).isEmpty)
    #expect(driver.apply(.deliveryPersisted(ordinal: 5, path: "x", latestPath: "y")).isEmpty)
    var after = driver.run
    after.log = before.log
    #expect(after == before)
  }

  // MARK: - Commands and waits

  @Test
  func failedCommandOffersRetry() throws {
    let definition = WorkflowDefinition(
      id: "ci", name: "CI",
      steps: [
        WorkflowStep(
          id: "test",
          verb: .run(
            WorkflowRunCommand(
              command: try Self.template("make test"), env: ["CI": try Self.template("${{ codans.cli }}")]))),
        WorkflowStep(id: "done", verb: .notify(try Self.template("exit ${{ steps.test.outputs.exit-code }}"))),
      ])
    let driver = Driver(Self.configuration(definition, bindings: [:], inputs: [:]))
    #expect(
      driver.startEffects == [
        .runCommand(
          stepID: "test", ordinal: 1, command: "make test", workingDirectory: "/w", environment: ["CI": "codans"],
          timeoutSeconds: 600),
        .persistRecord,
      ])
    driver.apply(
      .commandFinished(
        stepID: "test", exitCode: 2, stdout: "boom", stdoutPath: "/w/s/test.1.stdout.log", timedOut: false,
        spawnFailure: nil))
    let attention = try #require(driver.run.status.attention)
    #expect(attention.reason == .commandFailed)
    #expect(attention.actions == [.retry, .skip, .cancel])
    #expect(driver.run.stepOutputs["test"]?["exit-code"] == 2)
    #expect(driver.run.stepOutputs["test"]?["stdout"] == "boom")

    let retry = driver.user(.retry)
    #expect(
      retry.first
        == .runCommand(
          stepID: "test", ordinal: 2, command: "make test", workingDirectory: "/w", environment: ["CI": "codans"],
          timeoutSeconds: 600))
    let finished = driver.apply(
      .commandFinished(
        stepID: "test", exitCode: 0, stdout: "ok", stdoutPath: "/w/s/test.2.stdout.log", timedOut: false,
        spawnFailure: nil))
    #expect(finished.contains(.notify(title: "Workflow · CI", body: "exit 0")))
    #expect(driver.run.status == .completed)
  }

  @Test
  func continueOnErrorRecordsFailureAndMovesOn() throws {
    let definition = WorkflowDefinition(
      id: "ci", name: "CI",
      steps: [
        WorkflowStep(
          id: "lint", verb: .run(WorkflowRunCommand(command: try Self.template("lint"), continueOnError: true))),
        WorkflowStep(id: "done", verb: .notify(try Self.template("${{ steps.lint.outcome }}"))),
      ])
    let driver = Driver(Self.configuration(definition, bindings: [:], inputs: [:]))
    let effects = driver.apply(
      .commandFinished(stepID: "lint", exitCode: nil, stdout: "", stdoutPath: "", timedOut: true, spawnFailure: nil))
    #expect(effects.contains(.notify(title: "Workflow · CI", body: "failure")))
    #expect(driver.run.status == .completed)
  }

  @Test
  func waitTimeoutOffersKeepWaiting() throws {
    let definition = WorkflowDefinition(
      id: "w", name: "Wait",
      roles: [WorkflowRole(name: "reviewer", source: .pick)],
      steps: [WorkflowStep(id: "settle", verb: .wait(role: "reviewer", until: .idle, timeoutMinutes: 5))])
    let driver = Driver(
      Self.configuration(definition, bindings: ["reviewer": .pick(paneID: Self.reviewerPane)], inputs: [:]))
    #expect(
      driver.startEffects == [
        .awaitRole(role: "reviewer", paneID: Self.reviewerPane, until: .idle, timeoutMinutes: 5), .persistRecord,
      ])
    #expect(driver.run.phase == .waitingForState(role: "reviewer", until: .idle))
    let effects = driver.apply(.waitTimedOut(role: "reviewer"))
    #expect(effects == [.cancelRoleWait(role: "reviewer"), .persistRecord])
    let attention = try #require(driver.run.status.attention)
    #expect(attention.reason == .waitTimeout)
    #expect(attention.actions == [.keepWaiting, .skip, .cancel])
    #expect(
      driver.user(.keepWaiting) == [
        .awaitRole(role: "reviewer", paneID: Self.reviewerPane, until: .idle, timeoutMinutes: 5), .persistRecord,
      ])
    #expect(driver.apply(.roleIdle(role: "reviewer")).last == .finished(.completed))
    #expect(driver.run.steps["settle"]?.outcome == .success)
  }

  @Test
  func runInRoleTypesTheCommandWithoutExpecting() throws {
    let definition = WorkflowDefinition(
      id: "r", name: "Run",
      roles: [WorkflowRole(name: "author", source: .current)],
      steps: [
        WorkflowStep(
          id: "show", verb: .run(WorkflowRunCommand(command: try Self.template("git status"), inRole: "author")))
      ])
    let driver = Driver(
      Self.configuration(definition, bindings: ["author": .current(paneID: Self.authorPane)], inputs: [:]))
    #expect(
      driver.startEffects.first
        == .awaitRole(role: "author", paneID: Self.authorPane, until: .idle, timeoutMinutes: nil))
    #expect(
      driver.apply(.roleIdle(role: "author")) == [
        .inject(paneID: Self.authorPane, ordinal: 1, line: "git status"), .persistRecord,
      ])
    #expect(driver.apply(.injected(ordinal: 1)).last == .finished(.completed))
  }

  @Test
  func multilineTextFailsTheRun() throws {
    let definition = WorkflowDefinition(
      id: "m", name: "Multi",
      roles: [WorkflowRole(name: "author", source: .current)],
      steps: [
        WorkflowStep(
          id: "say", verb: .message(role: "author", content: .text(try Self.template("one\ntwo")), expect: nil))
      ])
    let driver = Driver(
      Self.configuration(definition, bindings: ["author": .current(paneID: Self.authorPane)], inputs: [:]))
    driver.apply(.roleIdle(role: "author"))
    guard case .failed(let step, let reason) = driver.run.status else {
      Issue.record("expected failed, got \(driver.run.status)")
      return
    }
    #expect(step == "say")
    #expect(reason.hasPrefix("RENDERED_TEXT_INVALID"))
  }

  // MARK: - Launch roles

  @Test
  func goneLaunchRoleOffersRelaunchWhichMintsAFreshActivation() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    let gone = driver.apply(.roleGone(role: "reviewer"))
    #expect(gone == [.disarmWatchdog(ordinal: 1), .persistRecord])
    let attention = try #require(driver.run.status.attention)
    #expect(attention.reason == .roleGone)
    #expect(attention.actions == [.relaunch, .skip, .cancel])

    let relaunch = driver.user(.relaunch)
    #expect(relaunch[0] == .revokeActivation(ordinal: 1))
    #expect(relaunch[1] == .openActivation(ordinal: 2, paneID: nil, token: "tok-2"))
    guard case .launch(let request) = relaunch[2] else {
      Issue.record("expected a launch, got \(relaunch)")
      return
    }
    #expect(request.ordinal == 2)
    #expect(request.environment["CODANS_WORKFLOW_TOKEN"] == "tok-2")
    #expect(driver.run.activations[1]?.state == .revoked)
    #expect(driver.run.status == .running)
    #expect(driver.run.phase == .launching(ordinal: 2))
    driver.apply(.launched(ordinal: 2, paneID: Self.authorPane))
    #expect(driver.run.bindings["reviewer"]?.paneID == Self.authorPane)
    #expect(driver.run.phase == .waitingForDelivery(ordinal: 2))
  }

  @Test
  func launchFailureOffersRelaunchOrCancel() throws {
    let driver = Driver(Self.configuration(try Self.reviewLoop()))
    driver.apply(.launchFailed(ordinal: 1, reason: "no profile"))
    let attention = try #require(driver.run.status.attention)
    #expect(attention.reason == .launchFailed)
    #expect(attention.actions == [.relaunch, .cancel])
    #expect(attention.message.contains("no profile"))
    #expect(driver.user(.skip).isEmpty)
    #expect(driver.run.status.attention != nil)
  }

  @Test
  func relaunchDuringAMessageStepReplaysThePromptAndRestartsTheStep() throws {
    let driver = try Self.afterKickoff()
    driver.apply(.roleIdle(role: "author"))
    driver.apply(.injected(ordinal: 2))
    _ = driver.deliver(2, token: "tok-2", body: "Fixed.")
    driver.apply(.deliveryPersisted(ordinal: 2, path: "/w/d/fixes.2.md", latestPath: "/w/d/fixes.md"))
    driver.apply(.roleGone(role: "reviewer"))
    let relaunch = driver.user(.relaunch)
    guard
      case .launch(let request) = relaunch.first(where: { if case .launch = $0 { return true } else { return false } })
    else {
      Issue.record("expected a launch, got \(relaunch)")
      return
    }
    #expect(request.prompt == "Review the uncommitted changes in this worktree. ")
    #expect(request.environment["CODANS_WORKFLOW_TOKEN"] == nil)
    let launched = driver.apply(.launched(ordinal: request.ordinal, paneID: Self.reviewerPane))
    #expect(
      launched.contains(.awaitRole(role: "reviewer", paneID: Self.reviewerPane, until: .idle, timeoutMinutes: nil)))
    #expect(driver.run.currentStepID == "re-review")
    #expect(driver.run.activations[3]?.state == .revoked)
    #expect(driver.run.currentActivation?.state == .waiting)
  }

  @Test
  func closeReleasesALaunchedPane() throws {
    let definition = WorkflowDefinition(
      id: "c", name: "Close",
      roles: [WorkflowRole(name: "reviewer", source: .launch)],
      steps: [
        WorkflowStep(id: "go", verb: .launch(role: "reviewer", prompt: try Self.template("Hi"), expect: nil)),
        WorkflowStep(id: "bye", verb: .close(role: "reviewer")),
      ])
    let driver = Driver(Self.configuration(definition, inputs: [:]))
    let effects = driver.apply(.launched(ordinal: 1, paneID: Self.reviewerPane))
    #expect(
      effects == [.closePane(paneID: Self.reviewerPane, role: "reviewer"), .persistRecord, .finished(.completed)])
    #expect(driver.run.bindings["reviewer"]?.paneID == nil)
  }

  // MARK: - Context and record

  @Test
  func contextExposesEveryNamespace() throws {
    let driver = try Self.afterKickoff()
    driver.machine.observe(role: "reviewer", state: "working")
    let context = driver.machine.context()
    #expect(context.value(at: ["workflow", "id"]) == "review-loop")
    #expect(context.value(at: ["run", "path"]) == .string(Self.runDirectory))
    #expect(context.value(at: ["worktree", "branch"]) == "main")
    #expect(context.value(at: ["roles", "reviewer", "agent"]) == "codex")
    #expect(context.value(at: ["roles", "reviewer", "name"]) == "Reviewer")
    #expect(context.value(at: ["roles", "reviewer", "state"]) == "working")
    #expect(context.value(at: ["roles", "author", "state"]) == .null)
    #expect(context.value(at: ["roles", "author", "pane-id"]) == .string(Self.authorPane.description))
    #expect(context.value(at: ["inputs", "max-rounds"]) == 3)
    #expect(context.value(at: ["state", "round"]) == 1)
    #expect(context.value(at: ["steps", "kickoff", "outcome"]) == "success")
    #expect(context.value(at: ["deliveries", "review", "verdict"]) == "issues")
    #expect(context.value(at: ["loop", "iteration"]) == 1)
    #expect(context.value(at: ["codans", "cli"]) == "codans")
  }

  @Test
  func recordCarriesNoTokenAndRoundTrips() throws {
    let driver = try Self.afterKickoff()
    let record = driver.run.record
    #expect(record.version == 1)
    #expect(record.workflowID == "review-loop")
    #expect(record.phase == "waiting_for_role")
    #expect(record.activations["2"]?.state == .waiting)
    #expect(record.bindings["reviewer"]?.paneID == Self.reviewerPane)
    let data = try WorkflowRunRecord.encoder.encode(record)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("tok-"))
    #expect(json.contains("\"workflow_id\""))
    #expect(json.contains("\"started_at\" : \"2023-11-14T22:13:20Z\""))
    #expect(json.contains("\"state\" : \"running\""))
    let decoded = try WorkflowRunRecord.decoder.decode(WorkflowRunRecord.self, from: data)
    #expect(decoded == record)

    driver.apply(.roleBlocked(role: "author"))
    let attentionData = try WorkflowRunRecord.encoder.encode(driver.run.record)
    let attentionRecord = try WorkflowRunRecord.decoder.decode(WorkflowRunRecord.self, from: attentionData)
    #expect(attentionRecord.status.attention?.reason == .roleBlocked)
    #expect(String(data: attentionData, encoding: .utf8)?.contains("\"needs_attention\"") == true)
  }

  @Test
  func stdoutIsTruncatedOnACharacterBoundary() {
    #expect(WorkflowMachine.truncated("héllo", toBytes: 2) == "h")
    #expect(WorkflowMachine.truncated("héllo", toBytes: 3) == "hé")
    #expect(WorkflowMachine.truncated("héllo", toBytes: 64) == "héllo")
  }
}
