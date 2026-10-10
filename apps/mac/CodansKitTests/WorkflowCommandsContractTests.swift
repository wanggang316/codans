import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import CodansKit

/// Contract tests for `codans workflow …`. The ArgumentParser leaves live in
/// the `codans-cli` executable target (not linkable here), so these drive
/// the `RPCClient` path each verb is built on against a scripted server:
/// the method and params the verb sends, and the response type it decodes.
@MainActor
struct WorkflowCommandsContractTests {
  private static let started = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private static func run(state: String = "running") -> IPC.WorkflowRunSummary {
    IPC.WorkflowRunSummary(
      runID: UUID(), workflowID: "review", workflowName: "Code Review", state: state,
      startedAt: started, runDirectory: "/repo/.codans/workflow-runs/abc",
      bindings: [IPC.WorkflowRoleBindingSummary(role: "author", source: "current", paneID: PaneID(), handle: "p1")],
      steps: [IPC.WorkflowStepSummary(id: "review", name: "Review")])
  }

  /// Scripts one call: asserts the real request's method, hands its params
  /// to `inspect`, and answers with `response`.
  private func exchange<Params: Decodable, Result: Encodable & Sendable>(
    _ method: IPC.Method,
    params: Params.Type,
    response: Result,
    inspect: @escaping @Sendable (Params) throws -> Void
  ) -> InMemoryTransport {
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == method)
      try inspect(try real.params.decoded(as: Params.self))
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: try JSONValue.encoded(response)),
      ]
    }
    return transport
  }

  private func client(_ transport: InMemoryTransport) -> RPCClient {
    RPCClient(transport: transport, versions: .init(clientVersion: "0.7.0"))
  }

  @Test
  func listSendsScopeAndDecodesWorkflows() async throws {
    let worktreeID = WorktreeID()
    let expected = IPC.WorkflowListResponse(workflows: [
      IPC.WorkflowSummary(
        id: "review", name: "Code Review", scope: .user, path: "/home/.codans/workflows/review.workflow.yaml",
        isEnabled: true, isValid: true)
    ])
    let transport = exchange(.workflowList, params: IPC.WorkflowListRequest.self, response: expected) { params in
      #expect(params.worktreeID == worktreeID)
      #expect(params.paneID == nil)
    }
    let result: IPC.WorkflowListResponse = try await client(transport).call(
      .workflowList, params: IPC.WorkflowListRequest(worktreeID: worktreeID))
    #expect(result == expected)
  }

  @Test
  func runSendsBindingsAndDecodesSelfInitiatedTask() async throws {
    let paneID = PaneID()
    let expected = IPC.WorkflowRunResponse(
      runID: UUID(), workflowID: "handoff", workflowName: "Handoff", runDirectory: "/repo/.codans/workflow-runs/x",
      bindings: [IPC.WorkflowRoleBindingSummary(role: "author", source: "current", paneID: paneID, handle: "p2")],
      selfInitiated: IPC.WorkflowSelfInitiatedTask(
        stepID: "brief", line: "Write the briefing.", completionCommand: "CODANS_WORKFLOW_TOKEN=t codans workflow deliver -"))
    let transport = exchange(.workflowRun, params: IPC.WorkflowRunRequest.self, response: expected) { params in
      #expect(params.workflow == "handoff")
      #expect(params.sourcePaneID == paneID)
      #expect(params.roles == ["reviewer": "auto"])
      #expect(params.inputs == ["scope": "src"])
      #expect(params.skip == ["lint"])
      #expect(params.origin == "cli")
    }
    let result: IPC.WorkflowRunResponse = try await client(transport).call(
      .workflowRun,
      params: IPC.WorkflowRunRequest(
        workflow: "handoff", sourcePaneID: paneID, roles: ["reviewer": "auto"], inputs: ["scope": "src"],
        skip: ["lint"]))
    #expect(result == expected)
    #expect(result.selfInitiated?.completionCommand.hasSuffix("deliver -") == true)
  }

  @Test
  func statusWithoutRunIDSendsTheCallerPane() async throws {
    let paneID = PaneID()
    let expected = IPC.WorkflowStatusResponse(
      run: Self.run(), participant: IPC.WorkflowParticipantSummary(role: "author", paneID: paneID))
    let transport = exchange(.workflowStatus, params: IPC.WorkflowStatusRequest.self, response: expected) { params in
      #expect(params.runID == nil)
      #expect(params.callerPaneID == paneID)
    }
    let result: IPC.WorkflowStatusResponse = try await client(transport).call(
      .workflowStatus, params: IPC.WorkflowStatusRequest(callerPaneID: paneID))
    #expect(result == expected)
    #expect(result.run.startedAt == Self.started)
  }

  @Test
  func deliverSendsTokenAndBodyAndDecodesProvisionalReceipt() async throws {
    let expected = IPC.WorkflowDeliverResponse(
      runID: UUID(), stepID: "review", delivery: "review", ordinal: 2, state: "provisional",
      path: "/repo/.codans/workflow-runs/abc/deliveries/review.2.md", issues: ["missing section: ## Findings"])
    let transport = exchange(.workflowDeliver, params: IPC.WorkflowDeliverRequest.self, response: expected) { params in
      #expect(params.token == "tok")
      #expect(params.body == "## Summary\nfine\n")
      #expect(params.verdict == "clean")
      #expect(params.force == false)
      #expect(params.runID == nil)
    }
    let result: IPC.WorkflowDeliverResponse = try await client(transport).call(
      .workflowDeliver,
      params: IPC.WorkflowDeliverRequest(token: "tok", body: "## Summary\nfine\n", verdict: "clean"))
    #expect(result == expected)
  }

  @Test
  func resolveSendsActionAndDecodesStatus() async throws {
    let runID = UUID()
    let expected = IPC.WorkflowStatusResponse(run: Self.run(state: "running"))
    let transport = exchange(.workflowResolve, params: IPC.WorkflowResolveRequest.self, response: expected) { params in
      #expect(params.runID == runID)
      #expect(params.action == "accept-with-verdict")
      #expect(params.verdict == "issues")
    }
    let result: IPC.WorkflowStatusResponse = try await client(transport).call(
      .workflowResolve, params: IPC.WorkflowResolveRequest(runID: runID, action: "accept-with-verdict", verdict: "issues"))
    #expect(result == expected)
  }

  @Test
  func cancelSendsRunIDAndDecodesStatus() async throws {
    let runID = UUID()
    let expected = IPC.WorkflowStatusResponse(run: Self.run(state: "cancelled"))
    let transport = exchange(.workflowCancel, params: IPC.WorkflowCancelRequest.self, response: expected) { params in
      #expect(params.runID == runID)
    }
    let result: IPC.WorkflowStatusResponse = try await client(transport).call(
      .workflowCancel, params: IPC.WorkflowCancelRequest(runID: runID))
    #expect(result.run.state == "cancelled")
  }

  @Test
  func listRunsSendsLimitAndDecodesRuns() async throws {
    let expected = IPC.WorkflowRunListResponse(runs: [Self.run(state: "completed"), Self.run()])
    let transport = exchange(.workflowListRuns, params: IPC.WorkflowListRunsRequest.self, response: expected) { params in
      #expect(params.limit == 5)
      #expect(params.worktreeID == nil)
    }
    let result: IPC.WorkflowRunListResponse = try await client(transport).call(
      .workflowListRuns, params: IPC.WorkflowListRunsRequest(limit: 5))
    #expect(result == expected)
  }

  @Test
  func domainErrorReachesTheClientIntact() async throws {
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      return [
        .success(id: hello.id, result: .object([:])),
        .error(id: real.id, error: .domain(code: "PANE_BUSY", message: "pane p3 is in run abc", hint: "cancel it")),
      ]
    }
    await #expect(throws: RPCClient.RPCError.ipc(.domain(code: "PANE_BUSY", message: "pane p3 is in run abc", hint: "cancel it"))) {
      let _: IPC.WorkflowRunResponse = try await client(transport).call(
        .workflowRun, params: IPC.WorkflowRunRequest(workflow: "review"))
    }
  }

  // MARK: - schema

  /// Every verb's `schemaVersion` is bound in the output schema, so a
  /// consumer validating `--json` against it never falls back to "any
  /// object" for a workflow verb.
  @Test
  func everyWorkflowVerbIsBoundInTheOutputSchema() throws {
    let schemaURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("codans-cli/Resources/schema/cli-output.schema.json")
    let schema = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any])
    let bindings = try #require(schema["allOf"] as? [[String: Any]])
    let bound = Set(
      bindings.compactMap { binding -> String? in
        let condition = binding["if"] as? [String: Any]
        let properties = condition?["properties"] as? [String: Any]
        let version = properties?["schemaVersion"] as? [String: Any]
        return version?["const"] as? String
      })
    let defs = try #require(schema["$defs"] as? [String: Any])
    for verb in ["list", "run", "status", "deliver", "resolve", "cancel", "runs"] {
      let version = OutputEnvelope.schemaVersion(command: "workflow.\(verb)")
      #expect(bound.contains(version), "\(version) is not bound in cli-output.schema.json")
    }
    for def in ["workflowList", "workflowRun", "workflowStatus", "workflowDeliver", "workflowRuns", "workflowRunSummary"] {
      #expect(defs[def] != nil, "$defs/\(def) missing")
    }
  }
}
