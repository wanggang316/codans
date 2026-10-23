import CodansCore
import Foundation
import Testing

@testable import Codans

/// Workspace creation and the source project list, through
/// `WorkspaceClient` on real git. A Workspace references the source main
/// checkouts from its `default` group; none of these operations creates a
/// branch, switches one, or touches a source directory.
@MainActor
struct WorkspaceSourcesTests {
  /// HEAD as both the symbolic ref and the commit, plus every local branch.
  private func gitState(_ fx: WorkspaceClientFixture, _ repo: String) throws -> [String] {
    [
      try fx.git(["symbolic-ref", "HEAD"], cwd: repo),
      try fx.git(["rev-parse", "HEAD"], cwd: repo),
      try fx.git(["for-each-ref", "--format=%(refname)", "refs/heads"], cwd: repo),
    ]
  }

  private func link(_ path: String) -> String? {
    try? FileManager.default.destinationOfSymbolicLink(atPath: path)
  }

  @Test
  func createWorkspaceReferencesSourcesWithoutCreatingOrSwitchingBranches() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let app = try fx.makeRepo(named: "src/app")
    let lib = try fx.makeRepo(named: "src/lib")
    // A source given by a subdirectory resolves to its repository root.
    try FileManager.default.createDirectory(atPath: "\(lib)/pkg", withIntermediateDirectories: true)
    let before = try [gitState(fx, app), gitState(fx, lib)]
    let root = fx.path("ws")

    let projectID = try await fx.client.createWorkspace(
      WorkspaceSourcePlan(
        title: "Checkout Flow", rootPath: root,
        sources: [.init(location: .local(path: app)), .init(location: .local(path: "\(lib)/pkg"))]))

    #expect(try [gitState(fx, app), gitState(fx, lib)] == before)
    let manifest = try WorkspaceManifestStore.loadGroups(rootPath: root)
    #expect(manifest.title == "Checkout Flow")
    #expect(manifest.projects == [.init(name: "app", sourceGitRoot: app), .init(name: "lib", sourceGitRoot: lib)])
    #expect(manifest.groups.map(\.kind) == [.default])
    #expect(manifest.groups.first?.path == "default")
    #expect(link("\(root)/default/app") == app)
    #expect(link("\(root)/default/lib") == lib)

    let project = try #require(fx.project(projectID))
    #expect(project.isWorkspace)
    #expect(project.rootPath == root)
    let defaultID = try #require(manifest.defaultGroup?.id)
    #expect(try fx.row(in: projectID, at: "\(root)/default").workspaceSlot?.role == .groupTerminal)
    #expect(try fx.row(in: projectID, at: app).workspaceSlot == WorkspaceSlot(groupID: defaultID, role: .reference))
    #expect(try fx.row(in: projectID, at: lib).workspaceSlot == WorkspaceSlot(groupID: defaultID, role: .reference))
  }

  @Test
  func createWorkspaceWithAMissingSourceLeavesNothingBehind() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let app = try fx.makeRepo(named: "src/app")
    let notRepo = fx.path("plain")
    try FileManager.default.createDirectory(atPath: notRepo, withIntermediateDirectories: true)
    let root = fx.path("ws")

    await #expect(throws: WorkspaceError.sourceNotRepository(path: notRepo)) {
      try await fx.client.createWorkspace(
        WorkspaceSourcePlan(
          title: "ws", rootPath: root,
          sources: [.init(location: .local(path: app)), .init(location: .local(path: notRepo))]))
    }
    #expect(!fx.exists(root))
    #expect(fx.manager.catalog.projects.isEmpty)
  }

  @Test
  func createWorkspaceRefusesARootInsideARepository() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let app = try fx.makeRepo(named: "src/app")
    let root = "\(app)/ws"

    await #expect(throws: WorkspaceError.rootInsideRepository(path: root, gitRoot: app)) {
      try await fx.client.createWorkspace(
        WorkspaceSourcePlan(title: "ws", rootPath: root, sources: [.init(location: .local(path: app))]))
    }
    #expect(!fx.exists(root))
  }

  /// A Workspace with `default` (app) and a named group `fix` (app member).
  private func makeWorkspaceWithNamedGroup(
    _ fx: WorkspaceClientFixture
  ) async throws -> (projectID: ProjectID, root: String, app: String, named: WorkspaceGroupsManifest.Group) {
    let app = try fx.makeRepo(named: "src/app")
    let root = fx.path("ws")
    try fx.addCheckout(of: app, at: "\(root)/fix/app", branch: "fix/login")
    let named = WorkspaceGroupsManifest.Group(
      id: WorkspaceGroupID(), name: "fix", kind: .named, path: "fix", branch: "fix/login",
      members: [
        .init(
          id: WorkspaceMemberID(), name: "app", path: "fix/app", sourceGitRoot: app,
          checkoutMode: .newBranch, branch: "fix/login", createdBranch: true)
      ])
    let manifest = WorkspaceGroupsManifest(
      title: "ws",
      projects: [.init(name: "app", sourceGitRoot: app)],
      groups: [.init(id: WorkspaceGroupID(), name: "default", kind: .default, path: "default"), named])
    let projectID = try await fx.registerWorkspace(manifest, rootPath: root)
    return (projectID, root, app, named)
  }

  @Test
  func addSourceAddsAReferenceAndLeavesNamedGroupsUnchanged() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let (projectID, root, _, named) = try await makeWorkspaceWithNamedGroup(fx)
    let lib = try fx.makeRepo(named: "src/lib")
    let before = try gitState(fx, lib)

    let rowID = try await fx.client.addSource(projectID, .init(location: .local(path: lib)))

    let manifest = try WorkspaceManifestStore.loadGroups(rootPath: root)
    #expect(manifest.projects.map(\.name) == ["app", "lib"])
    #expect(manifest.groups.first { $0.id == named.id } == named)
    #expect(link("\(root)/default/lib") == lib)
    let row = try fx.row(in: projectID, at: lib)
    #expect(row.id == rowID)
    #expect(row.workspaceSlot?.role == .reference)
    #expect(try gitState(fx, lib) == before)
    #expect(!fx.exists("\(root)/fix/lib"))
  }

  @Test
  func addSourceRefusesASourceTheWorkspaceAlreadyLists() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let (projectID, _, app, _) = try await makeWorkspaceWithNamedGroup(fx)

    await #expect(throws: WorkspaceError.sourceExists(path: app)) {
      try await fx.client.addSource(projectID, .init(location: .local(path: app)))
    }
  }

  @Test
  func removeSourceRemovesOnlyTheReference() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let (projectID, root, app, named) = try await makeWorkspaceWithNamedGroup(fx)
    let referenceID = try fx.row(in: projectID, at: app).id
    let memberID = try fx.row(in: projectID, at: "\(root)/fix/app").id
    let before = try gitState(fx, app)

    try await fx.client.removeSource(projectID, app)

    let manifest = try WorkspaceManifestStore.loadGroups(rootPath: root)
    #expect(manifest.projects.isEmpty)
    #expect(manifest.groups.first { $0.id == named.id } == named)
    #expect(!fx.exists("\(root)/default/app"))
    let rows = try #require(fx.project(projectID)).worktrees
    #expect(!rows.contains { $0.id == referenceID })
    #expect(rows.contains { $0.id == memberID })
    // The source and the named member checkout are untouched.
    #expect(fx.isDirectory("\(app)/.git"))
    #expect(try gitState(fx, app) == before)
    #expect(fx.isDirectory("\(root)/fix/app"))
  }

  @Test
  func removeSourceRefusesAnUnlistedSource() async throws {
    let fx = try WorkspaceClientFixture()
    defer { fx.cleanUp() }
    let (projectID, _, _, _) = try await makeWorkspaceWithNamedGroup(fx)
    let other = fx.path("src/other")

    await #expect(throws: WorkspaceError.sourceNotFound(path: other)) {
      try await fx.client.removeSource(projectID, other)
    }
  }
}
