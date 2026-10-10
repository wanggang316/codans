import Foundation
import Testing

@testable import Codans
@testable import CodansCore

/// Pins the popover's pure projections: step status against the run
/// record and cursor, role/pane pairing, attention action labels, and
/// skip-consequence text — all view-independent, so no `@MainActor`
/// engine or session is needed here.
struct WorkflowRunDisplayTests {
  private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
  private static let authorPane = PaneID(raw: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
  private static let reviewerProfile = UUID(uuidString: "00000000-0000-0000-0000-0000000000C0")!

  /// Same shape as `WorkflowEngineTests.yaml`: a `message` step with an
  /// `expect`, then a `notify` whose template requires that delivery —
  /// exactly the reference `skipConsequence` looks for.
  private static let yaml = """
    name: Ping
    roles:
      author:
        source: current
    steps:
      - id: ask
        message: author
        text: Summarize the diff.
        expect: {delivery: summary, verdicts: [clean, issues]}
      - id: done
        notify: Done ${{ deliveries.summary.path }}
    """

  private static func definition() throws -> WorkflowDefinition {
    let parsed = WorkflowDocumentParser.parse(yaml: yaml, id: "ping")
    let definition = try #require(parsed.definition)
    let diagnostics = parsed.diagnostics + WorkflowValidator.validate(definition)
    #expect(!diagnostics.hasErrors, "\(diagnostics)")
    return definition
  }

  private static func makeConfiguration(_ definition: WorkflowDefinition) -> WorkflowRunConfiguration {
    WorkflowRunConfiguration(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D0")!,
      definition: definition,
      source: WorkflowRunSource(
        projectID: ProjectID(), worktreeID: WorktreeID(), worktreePath: "/w", worktreeName: "w"),
      bindings: ["author": .current(paneID: authorPane)],
      runDirectory: "/w/.codans/workflow-runs/run",
      cliCommand: "codans",
      initiatorPaneID: authorPane,
      startedAt: epoch
    )
  }

  /// The machine right after `start`: cursor on "ask", waiting on the
  /// author, nothing delivered yet.
  private static func startedMachine() throws -> WorkflowMachine {
    let configuration = try makeConfiguration(definition())
    var minted = 0
    return WorkflowMachine.start(configuration, now: epoch) {
      minted += 1
      return "tok-\(minted)"
    }.machine
  }

  // MARK: - Step status

  @Test
  func currentStepIsTheCursorOnALiveRun() throws {
    let run = try Self.startedMachine().run
    let rows = WorkflowRunDisplay.stepRows(for: run)
    #expect(rows.map(\.id) == ["ask", "done"])
    #expect(rows[0].status == .current)
    #expect(rows[1].status == .pending)
  }

  @Test
  func recordedOutcomesWinOverTheCursor() throws {
    var run = try Self.startedMachine().run
    run.steps["ask"] = WorkflowStepRecord(stepID: "ask", outcome: .success)
    run.currentStepID = "done"
    let rows = WorkflowRunDisplay.stepRows(for: run)
    #expect(rows[0].status == .done)
    #expect(rows[1].status == .current)
  }

  @Test
  func skippedAndFailedOutcomesMapDirectly() throws {
    var run = try Self.startedMachine().run
    run.steps["ask"] = WorkflowStepRecord(stepID: "ask", outcome: .skipped)
    run.steps["done"] = WorkflowStepRecord(stepID: "done", outcome: .failure)
    let rows = WorkflowRunDisplay.stepRows(for: run)
    #expect(rows[0].status == .skipped)
    #expect(rows[1].status == .failed)
  }

  @Test
  func aFinishedRunHasNoCurrentStepEvenIfTheCursorStillPointsAtOne() throws {
    var run = try Self.startedMachine().run
    run.currentStepID = "done"
    run.status = .completed
    let rows = WorkflowRunDisplay.stepRows(for: run)
    // "done" never recorded an outcome (the test never ran it), and the
    // run is terminal, so it reads as pending rather than current — a
    // finished run has no live cursor.
    #expect(rows[1].status == .pending)
  }

  // MARK: - Roles

  @Test
  func roleRowsCarryTheBoundPaneOrNilForNotLaunchedYet() throws {
    let definition = WorkflowDefinition(
      id: "roles", name: "Roles",
      roles: [
        WorkflowRole(name: "author", source: .current),
        WorkflowRole(name: "reviewer", source: .launch),
      ],
      steps: [WorkflowStep(id: "noop", verb: .notify(try WorkflowTemplate.parse("hi")))]
    )
    var run = WorkflowRunState(
      configuration: WorkflowRunConfiguration(
        id: UUID(), definition: definition,
        source: WorkflowRunSource(
          projectID: ProjectID(), worktreeID: WorktreeID(), worktreePath: "/w", worktreeName: "w"),
        bindings: [
          "author": .current(paneID: Self.authorPane),
          "reviewer": .launch(profileID: Self.reviewerProfile, profileName: "Reviewer", agent: .codex, paneID: nil),
        ],
        runDirectory: "/w/.codans/workflow-runs/run", cliCommand: "codans", startedAt: Self.epoch))
    run.roleStates["author"] = "idle"
    let rows = WorkflowRunDisplay.roleRows(for: run)
    #expect(rows.map(\.id) == ["author", "reviewer"])
    #expect(rows[0].paneID == Self.authorPane)
    #expect(rows[0].state == "idle")
    #expect(rows[1].paneID == nil)
  }

  @Test
  func verdictOptionsComeFromTheCurrentActivation() throws {
    var run = try Self.startedMachine().run
    // The activation the machine opened entering "ask" carries the
    // step's declared verdicts.
    #expect(WorkflowRunDisplay.verdictOptions(for: run) == ["clean", "issues"])
    run.currentOrdinal = nil
    #expect(WorkflowRunDisplay.verdictOptions(for: run).isEmpty)
  }

  // MARK: - Action labels

  @Test
  func everyUserActionHasADisplayLabelAndAccessibilitySuffix() {
    for action in WorkflowUserAction.allCases {
      #expect(!action.displayLabel.isEmpty)
      #expect(!action.accessibilitySuffix.isEmpty)
    }
  }

  @Test
  func acceptWithVerdictLabelMatchesTheDesignDoc() {
    #expect(WorkflowUserAction.acceptWithVerdict.displayLabel == "Accept with Verdict…")
    #expect(WorkflowUserAction.accept.displayLabel == "Accept")
    #expect(WorkflowUserAction.skip.displayLabel == "Skip")
    #expect(WorkflowUserAction.cancel.displayLabel == "Cancel")
  }

  // MARK: - Skip consequence

  @Test
  func skippingAStepWithADependentDeliveryEndsTheRun() throws {
    let machine = try Self.startedMachine()
    let message = WorkflowRunDisplay.skipConfirmationMessage(machine: machine)
    let text = try #require(message)
    #expect(text.contains("done"))
  }

  @Test
  func noConsequenceOnceTheDeliveryAlreadyExists() throws {
    var machine = try Self.startedMachine()
    machine.run.deliveries["summary"] = WorkflowDeliveryRecord(
      name: "summary", ordinal: 1, path: "/w/summary.1.md", latestPath: "/w/summary.md", deliveredAt: Self.epoch)
    #expect(WorkflowRunDisplay.skipConfirmationMessage(machine: machine) == nil)
  }

  @Test
  func noConsequenceWhenTheCurrentStepHasNoExpectation() throws {
    var machine = try Self.startedMachine()
    // Move the cursor past "ask" onto "done", a bare `notify` with no
    // `expect` — mirrors `performSkip`'s own guard on `step.expectation`.
    machine.run.currentStepID = "done"
    #expect(WorkflowRunDisplay.skipConfirmationMessage(machine: machine) == nil)
  }
}
