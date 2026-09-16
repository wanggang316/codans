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
    #expect(
      try CLIWorkspaceMemberSource.resolve(
        projects: ["app"], repos: [], remotes: ["git@h:o/r.git"], minimum: 2)
        == [.project("app"), .remote("git@h:o/r.git")])
  }

  @Test
  func checkoutFlagsAreExclusiveAndResetNeedsATrackingRef() throws {
    let none = try CLIWorkspaceCheckoutFlags.resolve(existing: false, track: false, ref: nil, resetLocal: false)
    #expect(none == CLIWorkspaceCheckoutFlags())
    let existing = try CLIWorkspaceCheckoutFlags.resolve(existing: true, track: false, ref: nil, resetLocal: false)
    #expect(existing.useExistingBranch == true && existing.trackRemote == nil)
    let track = try CLIWorkspaceCheckoutFlags.resolve(existing: false, track: true, ref: nil, resetLocal: true)
    #expect(track.trackRemote == true && track.resetLocalBranch == true)
    let ref = try CLIWorkspaceCheckoutFlags.resolve(
      existing: false, track: false, ref: " origin/feat ", resetLocal: false)
    #expect(ref.remoteRef == "origin/feat" && ref.resetLocalBranch == nil)

    #expect(throws: CLIArgumentError.self) {
      try CLIWorkspaceCheckoutFlags.resolve(existing: true, track: true, ref: nil, resetLocal: false)
    }
    #expect(throws: CLIArgumentError.self) {
      try CLIWorkspaceCheckoutFlags.resolve(existing: true, track: false, ref: "origin/x", resetLocal: false)
    }
    #expect(throws: CLIArgumentError.self) {
      try CLIWorkspaceCheckoutFlags.resolve(existing: false, track: false, ref: nil, resetLocal: true)
    }
    #expect(throws: CLIArgumentError.self) {
      try CLIWorkspaceCheckoutFlags.resolve(existing: false, track: false, ref: "nobranch", resetLocal: false)
    }
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
      #expect(params.members.count == 3)
      #expect(params.members[0].projectID == appID)
      #expect(params.members[1].path == "/tmp/lib")
      #expect(params.members[2].remoteURL == "git@h:o/r.git")
      #expect(params.members[2].resetLocalBranch == true)
      #expect(params.trackRemote == true)
      #expect(params.cloneBaseDirectory == "/tmp/sources")
      let summary = IPC.WorkspaceSummary(
        projectID: workspaceID, title: "Checkout Flow", rootPath: "/tmp/ws",
        members: [
          IPC.WorkspaceMemberSummary(name: "app", path: "/tmp/ws/app", branch: "feat/x"),
          IPC.WorkspaceMemberSummary(
            name: "r", path: "/tmp/ws/r", branch: "feat/x", sourceGitRoot: "/tmp/sources/r",
            sourceKind: .remote, remoteURL: "git@h:o/r.git"),
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
        trackRemote: true,
        cloneBaseDirectory: "/tmp/sources",
        members: [
          IPC.WorkspaceMemberRequest(projectID: appID),
          IPC.WorkspaceMemberRequest(path: "/tmp/lib"),
          IPC.WorkspaceMemberRequest(remoteURL: "git@h:o/r.git", resetLocalBranch: true),
        ]))
    #expect(result.projectID == workspaceID)
    #expect(result.members.first?.branch == "feat/x")
    #expect(result.members.last?.sourceKind == .remote)
    #expect(result.members.last?.remoteURL == "git@h:o/r.git")
  }
}
