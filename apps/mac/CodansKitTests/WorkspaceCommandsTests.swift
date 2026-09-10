import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import CodansKit

/// Argument shaping and wire contract for `codans workspace …`. The
/// ArgumentParser leaves live in the executable target, so this pins the
/// member-source helper and the `RPCClient` encode/decode path for
/// `workspace.create`.
@MainActor
struct WorkspaceCommandsTests {
  @Test
  func memberSourcesKeepOrderAndEnforceCounts() throws {
    let sources = try CLIWorkspaceMemberSource.resolve(
      projects: ["app", "api"], repos: ["/tmp/lib"], minimum: 2)
    #expect(sources == [.project("app"), .project("api"), .repo("/tmp/lib")])

    #expect(throws: CLIArgumentError.self) {
      try CLIWorkspaceMemberSource.resolve(projects: ["app"], repos: [], minimum: 2)
    }
    #expect(throws: CLIArgumentError.self) {
      try CLIWorkspaceMemberSource.resolve(projects: ["app"], repos: ["/x"], minimum: 1, maximum: 1)
    }
    #expect(try CLIWorkspaceMemberSource.resolve(projects: [], repos: ["/x"], minimum: 1, maximum: 1) == [.repo("/x")])
  }

  @Test
  func createEncodesRequestAndDecodesSummary() async throws {
    let appID = ProjectID(raw: UUID())
    let workspaceID = ProjectID(raw: UUID())
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .workspaceCreate)
      let params = try real.params.decoded(as: IPC.WorkspaceCreateRequest.self)
      #expect(params.title == "Checkout Flow")
      #expect(params.branch == "feat/x")
      #expect(params.members.count == 2)
      #expect(params.members[0].projectID == appID)
      #expect(params.members[1].path == "/tmp/lib")
      let summary = IPC.WorkspaceSummary(
        projectID: workspaceID, title: "Checkout Flow", rootPath: "/tmp/ws",
        members: [
          IPC.WorkspaceMemberSummary(name: "app", path: "/tmp/ws/app", branch: "feat/x")
        ])
      let encoded = try JSONEncoder().encode(summary)
      let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
      return [
        .success(id: hello.id, result: .object([:])),
        .success(id: real.id, result: value),
      ]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.6.0"))
    let result: IPC.WorkspaceSummary = try await client.call(
      .workspaceCreate,
      params: IPC.WorkspaceCreateRequest(
        title: "Checkout Flow",
        branch: "feat/x",
        members: [
          IPC.WorkspaceMemberRequest(projectID: appID),
          IPC.WorkspaceMemberRequest(path: "/tmp/lib"),
        ]))
    #expect(result.projectID == workspaceID)
    #expect(result.members.first?.branch == "feat/x")
  }
}
