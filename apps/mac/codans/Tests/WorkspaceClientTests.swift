import CodansCore
import Foundation
import Testing

@testable import Codans

/// The shared `WorkspaceClientFixture` builds a group Workspace on real git
/// without the client's own creation flow, so creation and deletion tests
/// can start from the same state. Creation and deletion behavior is covered
/// in their own suites.
@MainActor
struct WorkspaceClientTests {
  @Test
  func fixtureRegistersAGroupWorkspaceWithReferencesAndMembers() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let app = try fx.makeRepo(named: "src/app")
    let root = fx.path("ws")
    let memberPath = (root as NSString).appendingPathComponent("fix/app")
    try fx.addCheckout(of: app, at: memberPath, branch: "fix/login")
    let defaultID = WorkspaceGroupID()
    let fixID = WorkspaceGroupID()
    let manifest = WorkspaceGroupsManifest(
      title: "ws",
      projects: [.init(name: "app", sourceGitRoot: app)],
      groups: [
        .init(id: defaultID, name: "default", kind: .default, path: "default"),
        .init(
          id: fixID, name: "fix", kind: .named, path: "fix", branch: "fix/login",
          members: [
            .init(
              id: WorkspaceMemberID(), name: "app", path: "fix/app", sourceGitRoot: app,
              branch: "fix/login", createdBranch: true)
          ]),
      ])

    let projectID = try await fx.registerWorkspace(manifest, rootPath: root)

    let project = try #require(fx.project(projectID))
    #expect(project.workspaceGroups.map(\.id) == [defaultID, fixID])
    #expect(try fx.row(in: projectID, at: "\(root)/default").workspaceSlot?.role == .groupTerminal)
    #expect(try fx.row(in: projectID, at: app).workspaceSlot == WorkspaceSlot(groupID: defaultID, role: .reference))
    let member = try fx.row(in: projectID, at: memberPath)
    #expect(member.workspaceSlot == WorkspaceSlot(groupID: fixID, role: .member))
    #expect(member.branch == "fix/login")
    #expect(try fx.row(in: projectID, at: "\(root)/fix").workspaceSlot?.role == .groupTerminal)
    #expect(fx.hierarchy.workspaceMembership(memberPath)?.projectID == projectID)
    #expect(fx.hierarchy.workspaceMembership(app) == nil)
  }
}
