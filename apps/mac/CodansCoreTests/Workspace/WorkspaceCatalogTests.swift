import Foundation
import Testing

@testable import CodansCore

/// The catalog-side half of the workspace model: the persisted `isWorkspace`
/// and `sourceGitRoot` fields, the derived kind, the membership lookup, and
/// the load-time marker repair.
struct WorkspaceCatalogTests {
  // MARK: - Kind

  @Test
  func workspaceOutranksGitRootButNotRemote() {
    let workspace = Project(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    #expect(workspace.kind == .workspace)
    #expect(!workspace.supportsWorktrees)

    // A stripped-and-probed gitRoot must not turn a workspace into a repo.
    let probed = Project(name: "ws", rootPath: "/tmp/ws", gitRoot: "/tmp", isWorkspace: true)
    #expect(probed.kind == .workspace)

    let host = RemoteHost(alias: "example.com", username: "alice", port: 22)
    let remote = Project(name: "ws", rootPath: "/srv/ws", remoteHost: host, isWorkspace: true)
    #expect(remote.kind == .server)
    #expect(ProjectKind.workspace.rawValue == "workspace")
  }

  @Test
  func repoRootPrefersTheRowsSourceOverTheProject() {
    let project = Project(name: "p", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    let plain = Worktree(name: "w", path: "/tmp/p-w")
    let child = Worktree(name: "c", path: "/tmp/ws/c", sourceGitRoot: "/src/c")
    #expect(project.repoRoot(for: plain) == "/tmp/p")
    #expect(project.repoRoot(for: child) == "/src/c")
    let workspace = Project(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    #expect(workspace.repoRoot(for: Worktree(name: "ws", path: "/tmp/ws")) == nil)
    #expect(workspace.isMainCheckout(Worktree(name: "ws", path: "/tmp/ws")))
    #expect(!workspace.isMainCheckout(child))
  }

  // MARK: - Codable

  @Test
  func isWorkspaceIsOmittedWhenFalseAndRoundTripsWhenTrue() throws {
    let plain = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(Project(name: "p", rootPath: "/tmp/p"))) as? [String: Any]
    #expect(plain?["isWorkspace"] == nil)

    let workspace = Project(name: "ws", rootPath: "/tmp/ws", isWorkspace: true)
    let data = try JSONEncoder().encode(workspace)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["isWorkspace"] as? Bool == true)
    let decoded = try JSONDecoder().decode(Project.self, from: data)
    #expect(decoded.isWorkspace)
    #expect(decoded.kind == .workspace)
    // Transient manifest never survives a round trip.
    #expect(decoded.workspace == nil)
  }

  @Test
  func sourceGitRootIsOmittedWhenNilAndRoundTripsWhenSet() throws {
    let plain = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(Worktree(name: "w", path: "/tmp/w"))) as? [String: Any]
    #expect(plain?["sourceGitRoot"] == nil)

    let child = Worktree(name: "c", path: "/tmp/ws/c", sourceGitRoot: "/src/c")
    let data = try JSONEncoder().encode(child)
    let decoded = try JSONDecoder().decode(Worktree.self, from: data)
    #expect(decoded.sourceGitRoot == "/src/c")
  }

  // MARK: - Membership

  @Test
  func membershipFindsChildRowsButNeverTheRoot() {
    let child = Worktree(name: "app", path: "/tmp/ws/app", sourceGitRoot: "/src/app")
    let workspace = Project(
      name: "ws", rootPath: "/tmp/ws",
      worktrees: [Worktree(name: "ws", path: "/tmp/ws"), child],
      isWorkspace: true)
    let repo = Project(
      name: "app", rootPath: "/src/app", gitRoot: "/src/app",
      worktrees: [Worktree(name: "main", path: "/src/app")])
    let catalog = Catalog(projects: [repo, workspace])

    let hit = catalog.workspaceMembership(forCanonicalPath: "/tmp/ws/app") { $0 }
    #expect(hit?.projectID == workspace.id)
    #expect(hit?.worktreeID == child.id)
    #expect(hit?.workspaceName == "ws")
    #expect(catalog.workspaceMembership(forCanonicalPath: "/tmp/ws") { $0 } == nil)
    #expect(catalog.workspaceMembership(forCanonicalPath: "/src/app") { $0 } == nil)
  }

  // MARK: - Marker repair

  @Test
  func repairFlagsManifestRootsAndClearsProbedGitRoot() {
    let stripped = Project(name: "ws", rootPath: "/tmp/ws", gitRoot: "/tmp")
    let local = Project(name: "p", rootPath: "/tmp/p", gitRoot: "/tmp/p")
    let host = RemoteHost(alias: "example.com", username: "alice", port: 22)
    let remote = Project(name: "r", rootPath: "/srv/ws", remoteHost: host)
    let already = Project(name: "done", rootPath: "/tmp/done", isWorkspace: true)
    var catalog = Catalog(projects: [stripped, local, remote, already])
    let hasManifest: (String) -> Bool = { path in
      path == "/tmp/ws" || path == "/srv/ws" || path == "/tmp/done"
    }

    let repaired = WorkspaceMarkerRepair.repair(&catalog, hasManifest: hasManifest)
    #expect(repaired)
    #expect(catalog.projects[0].isWorkspace)
    #expect(catalog.projects[0].gitRoot == nil)
    #expect(!catalog.projects[1].isWorkspace)
    #expect(catalog.projects[1].gitRoot == "/tmp/p")
    // Remote roots are never stat'd locally; already-flagged rows are left alone.
    #expect(!catalog.projects[2].isWorkspace)
    #expect(catalog.projects[3].isWorkspace)

    // Nothing left to repair → false.
    #expect(!WorkspaceMarkerRepair.repair(&catalog, hasManifest: hasManifest))
  }
}
