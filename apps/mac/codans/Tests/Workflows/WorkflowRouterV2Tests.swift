import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import Codans

@MainActor
struct WorkflowRouterV2Tests {
  @Test
  func currentAndLegacyRunsShareReadProtocolWithoutTemplateDecoding() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = WorkflowServiceV2(root: root.appendingPathComponent("v2"))
    let legacy = AgentWorkflowStore(root: root.appendingPathComponent("legacy"))
    let source = """
      schema: codans.workflow/v1
      id: tests.decision
      name: Decision
      nodes:
        decision:
          uses: codans/human.decide@v1
          with:
            question: {value: Proceed?}
            options: {value: [adopt, reject]}
            evidence: {value: A test proposal.}
      outputs:
        decision: {ref: nodes.decision.outputs.decision}
      """
    let definition = try WorkflowDefinitionParserV2.parse(source)
    let id = try service.start(
      definition: definition, source: source, title: "Current", inputs: [:], bindings: [:])
    let old = try legacy.create(id: UUID(), template: .advisor, title: "Legacy", input: "Review")
    let router = MethodRouter(
      systemHandlers: SystemHandlers(versions: .init(server: "test", appBundle: "test")),
      workflowStore: legacy, workflowServiceV2: service)
    let listing = try await call(router, .workflowList, JSONValue.object([:]))
    let rows = try listing.decoded(as: [JSONValue].self)
    #expect(rows.count == 2)
    let status = try await call(
      router, .workflowStatus, JSONValue.encoded(IPC.WorkflowRunRequest(runID: id)))
    #expect(try status.decoded(as: WorkflowRunV2.self).id == id)
    let oldStatus = try await call(
      router, .workflowStatus, JSONValue.encoded(IPC.WorkflowRunRequest(runID: old.id)))
    #expect(try oldStatus.decoded(as: AgentWorkflowRun.self).id == old.id)
    let cancelled = try await call(
      router, .workflowCancel, JSONValue.encoded(IPC.WorkflowRunRequest(runID: id)))
    #expect(try cancelled.decoded(as: WorkflowRunV2.self).status == "cancelled")
  }

  private func call(_ router: MethodRouter, _ method: IPC.Method, _ params: JSONValue) async throws
    -> JSONValue
  {
    switch await router.route(IPC.Request(id: UUID().uuidString, method: method, params: params)) {
    case .unary(let value): return value
    case .failed(let error): throw error
    case .streaming: throw IPCError.internal("Expected unary result")
    }
  }
}
