import Foundation
import Testing

@testable import CodansCore

/// Project identity is `(hostID, rootPath)` (ADR 0006): the catalog lookups
/// that find a Project by Host and path.
struct CatalogProjectIdentityTests {
  private let mini = HostRecord(address: "mini")

  /// Stands in for the app's symlink-resolving canonicalizer: maps `/tmp`
  /// to `/private/tmp` and strips a trailing slash.
  private static func canonicalize(_ path: String) -> String {
    var result = Project.normalizeRemotePath(path)
    if result == "/tmp" || result.hasPrefix("/tmp/") {
      result = "/private" + result
    }
    return result
  }

  private func server(_ rootPath: String, host: HostRecord? = nil) -> Project {
    let record = host ?? mini
    return Project(name: "srv", rootPath: rootPath, hostID: record.id, remoteHost: record.endpoint)
  }

  private func catalog(_ projects: [Project]) -> Catalog {
    Catalog(projects: projects, hosts: [mini])
  }

  // MARK: - This Mac

  @Test
  func localLookupMatchesSymlinkAndTrailingSlashForms() throws {
    let local = Project(name: "x", rootPath: "/private/tmp/x")
    let catalog = catalog([local])
    #expect(catalog.localProject(rootPath: "/tmp/x", canonicalize: Self.canonicalize)?.id == local.id)
    #expect(catalog.localProject(rootPath: "/private/tmp/x/", canonicalize: Self.canonicalize)?.id == local.id)
  }

  @Test
  func localLookupIgnoresServerProjectWithSamePath() {
    let catalog = catalog([server("/Users/me/dev/a")])
    #expect(catalog.localProject(rootPath: "/Users/me/dev/a", canonicalize: Self.canonicalize) == nil)
  }

  @Test
  func localLookupIgnoresLegacyServerProjectWithoutHostRecord() {
    let legacy = Project(name: "srv", rootPath: "/a", remoteHost: RemoteHost(alias: "box"))
    #expect(catalog([legacy]).localProject(rootPath: "/a", canonicalize: Self.canonicalize) == nil)
  }

  @Test
  func localLookupFindsLocalProjectBesideServerProject() {
    let local = Project(name: "a", rootPath: "/Users/me/dev/a")
    let catalog = catalog([server("/Users/me/dev/a"), local])
    #expect(catalog.localProject(rootPath: "/Users/me/dev/a", canonicalize: Self.canonicalize)?.id == local.id)
  }

  @Test
  func firstInOrderWinsOnExistingDuplicates() {
    let first = Project(name: "a", rootPath: "/a")
    let second = Project(name: "a2", rootPath: "/a")
    let catalog = catalog([first, second])
    #expect(catalog.localProject(rootPath: "/a", canonicalize: Self.canonicalize)?.id == first.id)
    #expect(catalog.localProject(containing: "/a/src", canonicalize: Self.canonicalize)?.id == first.id)
  }

  // MARK: - Host

  @Test
  func remotePathIsNotResolvedAgainstThisMac() {
    let remote = server("/tmp/x")
    let catalog = catalog([remote])
    #expect(catalog.project(onHost: mini.id, rootPath: "/tmp/x/", canonicalizeLocal: Self.canonicalize)?.id == remote.id)
    #expect(catalog.project(onHost: mini.id, rootPath: "/private/tmp/x", canonicalizeLocal: Self.canonicalize) == nil)
  }

  @Test
  func hostLookupKeepsHostsApart() {
    let other = HostRecord(address: "other")
    let onOther = server("/a", host: other)
    let local = Project(name: "a", rootPath: "/a")
    let catalog = Catalog(projects: [onOther, local], hosts: [mini, other])
    #expect(catalog.project(onHost: mini.id, rootPath: "/a", canonicalizeLocal: Self.canonicalize) == nil)
    #expect(catalog.project(onHost: other.id, rootPath: "/a", canonicalizeLocal: Self.canonicalize)?.id == onOther.id)
    #expect(catalog.project(onHost: nil, rootPath: "/a", canonicalizeLocal: Self.canonicalize)?.id == local.id)
  }

  // MARK: - Edit conflict

  @Test
  func editConflictFindsAnotherProjectWithTheHostAndPath() {
    let edited = server("/a")
    let other = server("/b/")
    let catalog = catalog([edited, other])
    let conflict = catalog.projectConflicting(
      withEditOf: edited.id, onHost: mini.id, rootPath: "/b", canonicalizeLocal: Self.canonicalize)
    #expect(conflict?.id == other.id)
  }

  @Test
  func editKeepingTheOwnHostAndPathIsNoConflictAlsoWithAnExistingDuplicate() {
    let duplicate = server("/a")
    let edited = server("/a")
    let catalog = catalog([duplicate, edited])
    let conflict = catalog.projectConflicting(
      withEditOf: edited.id, onHost: mini.id, rootPath: "/a/", canonicalizeLocal: Self.canonicalize)
    #expect(conflict == nil)
  }

  @Test
  func editToAPathOnlyALocalProjectHasIsNoConflict() {
    let edited = server("/a")
    let catalog = catalog([edited, Project(name: "b", rootPath: "/b")])
    let conflict = catalog.projectConflicting(
      withEditOf: edited.id, onHost: mini.id, rootPath: "/b", canonicalizeLocal: Self.canonicalize)
    #expect(conflict == nil)
  }

  // MARK: - Contains path

  @Test
  func containsReturnsDeepestLocalRootAndNeverServerProject() {
    let outer = Project(name: "repo", rootPath: "/repo")
    let inner = Project(name: "sub", rootPath: "/repo/sub")
    let deeperServer = server("/repo/sub/pkg")
    let catalog = catalog([outer, deeperServer, inner])
    let match = catalog.localProject(containing: "/repo/sub/pkg/file", canonicalize: Self.canonicalize)
    #expect(match?.id == inner.id)
  }

  @Test
  func containsRespectsPathSegmentBoundary() {
    let catalog = catalog([Project(name: "repo", rootPath: "/repo")])
    #expect(catalog.localProject(containing: "/repository", canonicalize: Self.canonicalize) == nil)
  }

  @Test
  func containsNeverReturnsServerProject() {
    let catalog = catalog([server("/repo")])
    #expect(catalog.localProject(containing: "/repo/src", canonicalize: Self.canonicalize) == nil)
  }

  // MARK: - Git root

  @Test
  func gitRootLookupMatchesLocalProjectOnly() {
    var remote = server("/repo")
    remote.gitRoot = "/repo"
    let local = Project(name: "repo", rootPath: "/tmp/repo", gitRoot: "/tmp/repo")
    let catalog = catalog([remote, local])
    #expect(catalog.localProject(gitRoot: "/private/tmp/repo", canonicalize: Self.canonicalize)?.id == local.id)
    #expect(catalog.localProject(gitRoot: "/repo", canonicalize: Self.canonicalize) == nil)
  }

  // MARK: - Workspace membership

  @Test
  func workspaceMembershipIgnoresServerWorkspace() {
    let member = Worktree(
      name: "app", path: "/ws/app",
      workspaceSlot: WorkspaceSlot(groupID: WorkspaceGroupID(), role: .member))
    var remote = server("/ws")
    remote.isWorkspace = true
    remote.worktrees = [member]
    let catalog = catalog([remote])
    #expect(catalog.workspaceMembership(forCanonicalPath: "/ws/app", canonicalize: Self.canonicalize) == nil)
  }

  // MARK: - Git transport

  @Test
  func gitURLKeepsThePathAndNamesTheHost() {
    let remote = server("/Users/me/dev/a b")
    let url = remote.gitURL("/Users/me/dev/a b")
    #expect(url.path(percentEncoded: false) == "/Users/me/dev/a b")
    #expect(GitLocation.hostID(of: url) == mini.id)

    let local = Project(name: "a", rootPath: "/Users/me/dev/a")
    let localURL = local.gitURL("/Users/me/dev/a")
    #expect(localURL.isFileURL)
    #expect(GitLocation.hostID(of: localURL) == nil)
  }

  /// A local Project and a Server project at the same path: each git call
  /// runs on its own machine.
  @Test
  func gitTransportFollowsProjectIdentityForSamePath() {
    var remote = server("/Users/me/dev/a")
    remote.gitRoot = "/Users/me/dev/a"
    let local = Project(name: "a", rootPath: "/Users/me/dev/a", gitRoot: "/Users/me/dev/a")
    for catalog in [catalog([remote, local]), catalog([local, remote])] {
      let localHost = catalog.gitRemoteHost(
        for: local.gitURL("/Users/me/dev/a"), canonicalizeLocal: Self.canonicalize)
      let remoteHost = catalog.gitRemoteHost(
        for: remote.gitURL("/Users/me/dev/a"), canonicalizeLocal: Self.canonicalize)
      #expect(localHost == nil)
      #expect(remoteHost == mini.endpoint)
    }
  }

  @Test
  func plainPathOfServerProjectStillRoutesToItsHost() {
    let feature = Worktree(name: "f", path: "/tmp/app-feature")
    var remote = server("/tmp/app")
    remote.worktrees = [feature]
    let catalog = catalog([remote])
    let url = URL(fileURLWithPath: "/tmp/app-feature/")
    #expect(catalog.gitRemoteHost(for: url, canonicalizeLocal: Self.canonicalize) == mini.endpoint)
    #expect(
      catalog.gitRemoteHost(for: URL(fileURLWithPath: "/elsewhere"), canonicalizeLocal: Self.canonicalize) == nil)
  }

  @Test
  func plainPathOwnedByThisMacProjectNeverRoutesToAHost() {
    let local = Project(
      name: "a", rootPath: "/private/tmp/a",
      worktrees: [Worktree(name: "f", path: "/private/tmp/a-f")])
    let catalog = catalog([server("/tmp/a-f"), local])
    // `/tmp/a-f` is the local worktree in its symlink form.
    let url = URL(fileURLWithPath: "/tmp/a-f")
    #expect(catalog.gitRemoteHost(for: url, canonicalizeLocal: Self.canonicalize) == nil)
  }
}
