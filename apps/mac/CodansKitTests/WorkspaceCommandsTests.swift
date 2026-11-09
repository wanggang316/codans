import CodansCore
import CodansIPC
import Foundation
import Testing

@testable import CodansKit

/// Argument shaping and wire contract for `codans workspace …`. The
/// ArgumentParser leaves live in the executable target, so this pins the
/// source helper, the agent-profile match, and the `RPCClient`
/// encode/decode path for `workspace.create` and `workspace.createGroup`.
@MainActor
struct WorkspaceCommandsTests {
  @Test
  func sourcesKeepOrderAndEnforceCounts() throws {
    let sources = try CLIWorkspaceMemberSource.resolve(
      projects: ["app", "api"], repos: ["/tmp/lib"], minimum: 1)
    #expect(sources == [.project("app"), .project("api"), .repo("/tmp/lib")])

    #expect(throws: CLIArgumentError.self) {
      try CLIWorkspaceMemberSource.resolve(projects: [], repos: [], minimum: 1)
    }
    #expect(throws: CLIArgumentError.self) {
      try CLIWorkspaceMemberSource.resolve(projects: ["app"], repos: ["/x"], minimum: 1, maximum: 1)
    }
    #expect(
      try CLIWorkspaceMemberSource.resolve(
        projects: ["app"], repos: [], remotes: ["git@h:o/r.git"], minimum: 1)
        == [.project("app"), .remote("git@h:o/r.git")])
  }

  @Test
  func agentProfileMatchesByIDOrNameAndRefusesDisabledProfiles() throws {
    let claude = Self.profile("Claude Code", enabled: true)
    let codex = Self.profile("Codex", enabled: false)
    #expect(try CLIAgentProfileMatch.resolve("claude code", in: [claude, codex]) == claude)
    #expect(try CLIAgentProfileMatch.resolve(claude.id.uuidString.lowercased(), in: [claude, codex]) == claude)
    #expect(throws: CLIArgumentError.self) { try CLIAgentProfileMatch.resolve("Codex", in: [claude, codex]) }
    #expect(throws: CLIArgumentError.self) { try CLIAgentProfileMatch.resolve("gemini", in: [claude, codex]) }
  }

  @Test
  func listedProjectsCarryEachRowsGroupAndRole() throws {
    let group = WorkspaceGroupRecord(id: WorkspaceGroupID(), name: "feat", kind: .named)
    let groupRow = Worktree(
      name: "feat", path: "/ws/feat", workspaceSlot: .init(groupID: group.id, role: .groupTerminal))
    let member = Worktree(
      name: "app", path: "/ws/feat/app", branch: "feat/x", sourceGitRoot: "/src/app",
      workspaceSlot: .init(groupID: group.id, role: .member))
    let loose = Worktree(name: "old", path: "/ws/old")
    let project = Project(
      name: "ws", rootPath: "/ws", worktrees: [groupRow, member, loose], isWorkspace: true, workspaceGroups: [group])

    // `codans tree` reads the projects `hierarchy.listProjects` encodes.
    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))

    #expect(
      decoded.worktrees.map { IPC.WorkspaceGroupRef(worktree: $0, in: decoded) } == [
        IPC.WorkspaceGroupRef(id: group.id, name: "feat", role: .groupTerminal),
        IPC.WorkspaceGroupRef(id: group.id, name: "feat", role: .member),
        nil,
      ])
    let plain = Project(name: "app", rootPath: "/src/app", worktrees: [member])
    #expect(IPC.WorkspaceGroupRef(worktree: member, in: plain) == nil)
  }

  @Test
  func createEncodesSourcesAndDecodesSummary() async throws {
    let appID = ProjectID(raw: UUID())
    let workspaceID = ProjectID(raw: UUID())
    let groupID = WorkspaceGroupID()
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .workspaceCreate)
      let params = try real.params.decoded(as: IPC.WorkspaceCreateRequest.self)
      #expect(params.title == "Checkout Flow")
      #expect(params.projects.map(\.projectID) == [appID, nil, nil])
      #expect(params.projects[1].path == "/tmp/lib")
      #expect(params.projects[2].remoteURL == "git@h:o/r.git")
      #expect(params.cloneBaseDirectory == "/tmp/sources")
      let summary = IPC.WorkspaceSummary(
        projectID: workspaceID, title: "Checkout Flow", rootPath: "/tmp/ws",
        projects: [
          IPC.WorkspaceProjectSummary(name: "app", sourceGitRoot: "/src/app", branch: "main"),
          IPC.WorkspaceProjectSummary(
            name: "r", sourceGitRoot: "/tmp/sources/r", sourceKind: .remote, remoteURL: "git@h:o/r.git"),
        ],
        groups: [
          IPC.WorkspaceGroupSummary(
            id: groupID, name: "default", isDefault: true, path: "/tmp/ws/default",
            members: [IPC.WorkspaceGroupMemberSummary(name: "app", path: "/src/app", role: .reference)])
        ])
      let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(summary))
      return [.success(id: hello.id, result: .object([:])), .success(id: real.id, result: value)]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.6.0"))
    let result: IPC.WorkspaceSummary = try await client.call(
      .workspaceCreate,
      params: IPC.WorkspaceCreateRequest(
        title: "Checkout Flow",
        cloneBaseDirectory: "/tmp/sources",
        projects: [
          IPC.WorkspaceSourceRequest(projectID: appID),
          IPC.WorkspaceSourceRequest(path: "/tmp/lib"),
          IPC.WorkspaceSourceRequest(remoteURL: "git@h:o/r.git"),
        ]))
    #expect(result.projectID == workspaceID)
    #expect(result.projects.last?.sourceKind == .remote)
    #expect(result.groups.first?.members.first?.role == .reference)
  }

  @Test
  func createGroupEncodesOverridesAndDecodesSetupFailures() async throws {
    let workspaceID = ProjectID(raw: UUID())
    let groupID = WorkspaceGroupID()
    let transport = InMemoryTransport()
    transport.script = { frames in
      let hello = try JSONDecoder().decode(IPC.Request.self, from: frames[0])
      let real = try JSONDecoder().decode(IPC.Request.self, from: frames[1])
      #expect(real.method == .workspaceCreateGroup)
      let params = try real.params.decoded(as: IPC.WorkspaceGroupCreateRequest.self)
      #expect(
        params
          == IPC.WorkspaceGroupCreateRequest(
            projectID: workspaceID, name: "feat", branch: "feat/x", baseRefs: ["app": "origin/dev"], fetch: false))
      let response = IPC.WorkspaceGroupCreateResponse(
        projectID: workspaceID,
        group: IPC.WorkspaceGroupSummary(
          id: groupID, name: "feat", isDefault: false, path: "/tmp/ws/feat",
          members: [
            IPC.WorkspaceGroupMemberSummary(
              name: "app", path: "/tmp/ws/feat/app", branch: "feat/x", role: .member, worktreeID: WorktreeID())
          ]),
        setupFailures: [.init(name: "app", reason: "exit 1")])
      let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(response))
      return [.success(id: hello.id, result: .object([:])), .success(id: real.id, result: value)]
    }
    let client = RPCClient(transport: transport, versions: .init(clientVersion: "0.6.0"))
    let result: IPC.WorkspaceGroupCreateResponse = try await client.call(
      .workspaceCreateGroup,
      params: IPC.WorkspaceGroupCreateRequest(
        projectID: workspaceID, name: "feat", branch: "feat/x", baseRefs: ["app": "origin/dev"], fetch: false))
    #expect(result.group.id == groupID)
    #expect(result.group.members.map(\.role) == [.member])
    #expect(result.setupFailures == [.init(name: "app", reason: "exit 1")])
  }

  @Test
  func groupDeletionCheckAndOutcomeRoundTrip() throws {
    let check = GroupDeletionCheck(
      projectID: ProjectID(), groupID: WorkspaceGroupID(), groupName: "feat",
      members: [
        .init(
          name: "app", worktreeID: WorktreeID(), path: "/ws/feat/app", branch: "feat/x", uncommittedCount: 2,
          deletableBranches: ["feat/x"])
      ],
      busyPaneIDs: [PaneID()], extraEntries: ["notes.txt"])
    #expect(try JSONDecoder().decode(GroupDeletionCheck.self, from: JSONEncoder().encode(check)) == check)
    let response = IPC.WorkspaceGroupDeleteResponse(
      projectID: check.projectID, groupID: check.groupID, groupName: "feat",
      outcome: GroupDeletionOutcome(
        deletedGroup: false, failures: [.init(name: "app", path: "/ws/feat/app", reason: "locked")]))
    #expect(
      try JSONDecoder().decode(IPC.WorkspaceGroupDeleteResponse.self, from: JSONEncoder().encode(response))
        == response)
  }

  private static func profile(_ name: String, enabled: Bool) -> IPC.AgentProfileSummary {
    IPC.AgentProfileSummary(
      id: UUID(), name: name, agent: "claude", agentName: name, isEnabled: enabled, isInstalled: true,
      supportsPrompt: true, command: "claude")
  }
}
