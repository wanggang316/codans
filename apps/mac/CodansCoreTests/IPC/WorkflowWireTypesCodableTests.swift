import Foundation
import Testing

@testable import CodansCore
@testable import CodansIPC

/// Every `workflow.*` request and response survives the same
/// `JSONValue.encoded` / `decoded` path `RPCClient` and the router use, so
/// the shapes here are what the two sides actually exchange.
struct WorkflowWireTypesCodableTests {
  /// Whole seconds: the default `Date` coding is a double and sub-second
  /// noise would make an otherwise faithful round trip look lossy.
  private static let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private static let finished = Date(timeIntervalSinceReferenceDate: 800_000_600)

  private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let json = try JSONValue.encoded(value)
    return try json.decoded(as: T.self)
  }

  static func sampleBinding() -> IPC.WorkflowRoleBindingSummary {
    IPC.WorkflowRoleBindingSummary(
      role: "reviewer", source: "launch", paneID: PaneID(), handle: "p4",
      profileID: UUID(), profileName: "Claude Code", agent: "claude")
  }

  static func sampleRun() -> IPC.WorkflowRunSummary {
    IPC.WorkflowRunSummary(
      runID: UUID(),
      workflowID: "review",
      workflowName: "Code Review",
      state: "needs_attention",
      dependent: nil,
      attention: IPC.WorkflowAttentionSummary(
        reason: "provisional_delivery", message: "review is missing ## Findings", stepID: "review",
        role: "reviewer", ordinal: 3, actions: ["accept", "accept-with-verdict", "ask-again", "skip", "cancel"],
        issues: ["missing section: ## Findings"]),
      startedAt: started,
      finishedAt: nil,
      runDirectory: "/repo/.codans/workflow-runs/abc",
      worktreeID: WorktreeID(),
      currentStep: IPC.WorkflowStepSummary(id: "review", name: "Review", outcome: nil, iteration: nil),
      phase: "waiting_for_delivery",
      activation: IPC.WorkflowActivationSummary(
        stepID: "review", role: "reviewer", delivery: "review", state: "provisional", ordinal: 3,
        deadline: finished, completionCommands: ["CODANS_WORKFLOW_TOKEN=x codans workflow deliver -"]),
      deliveries: [
        IPC.WorkflowDeliverySummary(
          name: "review", ordinal: 3, path: "/repo/.codans/workflow-runs/abc/deliveries/review.3.md",
          latestPath: "/repo/.codans/workflow-runs/abc/deliveries/review.md", verdict: nil, isProvisional: true)
      ],
      bindings: [sampleBinding(), IPC.WorkflowRoleBindingSummary(role: "author", source: "current", paneID: PaneID())],
      steps: [
        IPC.WorkflowStepSummary(id: "step-1", name: nil, outcome: "success", iteration: nil),
        IPC.WorkflowStepSummary(id: "review", name: "Review", outcome: nil, iteration: nil),
      ])
  }

  @Test
  func listRequestAndResponseRoundTrip() throws {
    let request = IPC.WorkflowListRequest(worktreeID: WorktreeID(), paneID: nil)
    #expect(try roundTrip(request) == request)
    #expect(try roundTrip(IPC.WorkflowListRequest()) == IPC.WorkflowListRequest())

    let summary = IPC.WorkflowSummary(
      id: "review", name: "Code Review", description: "Reviews a branch", scope: .repo,
      path: "/repo/.codans/workflows/review.workflow.yaml", isEnabled: true, isValid: false,
      diagnostics: [.error("undefined_role", "role `qa` is not declared", at: "steps[2].message")],
      roles: [IPC.WorkflowRoleSummary(name: "reviewer", source: "launch", agents: ["claude"], profile: "Claude Code")],
      inputs: [
        IPC.WorkflowInputSummary(
          name: "scope", kind: "choice", required: false, defaultValue: .string("src"),
          description: "What to review", options: ["src", "tests"]),
        IPC.WorkflowInputSummary(name: "depth", kind: "number", required: true, defaultValue: .int(2)),
      ],
      requiresTrust: true, isTrusted: false)
    let response = IPC.WorkflowListResponse(workflows: [summary])
    #expect(try roundTrip(response) == response)
  }

  @Test
  func scopeWireStringsAreStable() {
    #expect(IPC.WorkflowScope.allCases.map(\.rawValue) == ["bundle", "user", "repo"])
  }

  @Test
  func runRequestAndResponseRoundTrip() throws {
    let request = IPC.WorkflowRunRequest(
      workflow: "review", sourcePaneID: PaneID(), worktreeID: nil,
      roles: ["reviewer": "auto"], inputs: ["scope": "src"], skip: ["lint"], origin: "cli")
    #expect(try roundTrip(request) == request)

    let response = IPC.WorkflowRunResponse(
      runID: UUID(), workflowID: "review", workflowName: "Code Review",
      runDirectory: "/repo/.codans/workflow-runs/abc",
      bindings: [Self.sampleBinding()],
      selfInitiated: IPC.WorkflowSelfInitiatedTask(
        stepID: "brief", line: "Read /repo/.codans/workflow-runs/abc/instructions/brief.1.md",
        instructionPath: "/repo/.codans/workflow-runs/abc/instructions/brief.1.md",
        completionCommand: "CODANS_WORKFLOW_TOKEN=t codans workflow deliver -"))
    #expect(try roundTrip(response) == response)
    let bare = IPC.WorkflowRunResponse(
      runID: UUID(), workflowID: "review", workflowName: "Code Review", runDirectory: "/tmp", bindings: [])
    #expect(try roundTrip(bare) == bare)
  }

  @Test
  func statusRequestAndResponseRoundTrip() throws {
    let byRun = IPC.WorkflowStatusRequest(runID: UUID(), callerPaneID: nil)
    #expect(try roundTrip(byRun) == byRun)
    let byCaller = IPC.WorkflowStatusRequest(runID: nil, callerPaneID: PaneID())
    #expect(try roundTrip(byCaller) == byCaller)

    let response = IPC.WorkflowStatusResponse(
      run: Self.sampleRun(),
      participant: IPC.WorkflowParticipantSummary(role: "reviewer", paneID: PaneID()))
    #expect(try roundTrip(response) == response)
  }

  @Test
  func runSummaryDatesSurviveTheWire() throws {
    let run = Self.sampleRun()
    let decoded = try roundTrip(run)
    #expect(decoded.startedAt == Self.started)
    #expect(decoded.activation?.deadline == Self.finished)
    #expect(decoded.finishedAt == nil)
  }

  @Test
  func deliverRequestAndResponseRoundTrip() throws {
    let request = IPC.WorkflowDeliverRequest(
      callerPaneID: PaneID(), token: "t", runID: UUID(), stepID: "review",
      body: "## Findings\nnone\n", verdict: "clean", force: true)
    #expect(try roundTrip(request) == request)
    let minimal = IPC.WorkflowDeliverRequest(body: "x")
    #expect(try roundTrip(minimal) == minimal)

    let response = IPC.WorkflowDeliverResponse(
      runID: UUID(), stepID: "review", delivery: "review", ordinal: 3, state: "provisional",
      path: "/repo/.codans/workflow-runs/abc/deliveries/review.3.md", issues: ["missing verdict"])
    #expect(try roundTrip(response) == response)
  }

  @Test
  func resolveAndCancelRequestsRoundTrip() throws {
    let resolve = IPC.WorkflowResolveRequest(runID: UUID(), action: "accept-with-verdict", verdict: "issues")
    #expect(try roundTrip(resolve) == resolve)
    let cancel = IPC.WorkflowCancelRequest(runID: UUID())
    #expect(try roundTrip(cancel) == cancel)
  }

  @Test
  func listRunsRequestAndResponseRoundTrip() throws {
    let request = IPC.WorkflowListRunsRequest(worktreeID: nil, paneID: PaneID(), limit: 20)
    #expect(try roundTrip(request) == request)
    let response = IPC.WorkflowRunListResponse(runs: [Self.sampleRun(), Self.sampleRun()])
    #expect(try roundTrip(response) == response)
  }

  @Test
  func methodStringsAreStable() {
    #expect(IPC.Method.workflowList.rawValue == "workflow.list")
    #expect(IPC.Method.workflowRun.rawValue == "workflow.run")
    #expect(IPC.Method.workflowStatus.rawValue == "workflow.status")
    #expect(IPC.Method.workflowDeliver.rawValue == "workflow.deliver")
    #expect(IPC.Method.workflowResolve.rawValue == "workflow.resolve")
    #expect(IPC.Method.workflowCancel.rawValue == "workflow.cancel")
    #expect(IPC.Method.workflowListRuns.rawValue == "workflow.listRuns")
  }
}
