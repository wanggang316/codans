import Foundation
import Testing

@testable import CodansCore

struct WorkspaceMembershipIndexTests {
  @Test
  func aliasesMatchAndUnrelatedChangesDoNotResolvePathsAgain() {
    let child = Worktree(name: "app", path: "/real/ws/app")
    let mirror = Worktree(name: "mirror", path: "/alias/ws/app")
    var catalog = Catalog(projects: [
      Project(name: "ws", rootPath: "/real/ws", worktrees: [child], isWorkspace: true),
      Project(name: "source", rootPath: "/src", worktrees: [mirror]),
    ])
    var index = WorkspaceMembershipIndex()
    var calls = 0
    let normalize: (String) -> String = { path in
      calls += 1
      return path.replacingOccurrences(of: "/alias", with: "/real")
    }
    index.update(catalog: catalog, canonicalize: normalize)
    #expect(index.memberships[mirror.id]?.worktreeID == child.id)
    let initialCalls = calls
    #expect(initialCalls == 3)
    catalog.projects[1].worktrees[0].name = "Renamed"
    catalog.projects[1].worktrees[0].isPinned = true
    catalog.projects[1].selectedWorktreeID = mirror.id
    index.update(catalog: catalog, canonicalize: normalize)
    #expect(calls == initialCalls)

    catalog.projects[0].displayName = "Updated workspace"
    index.update(catalog: catalog, canonicalize: normalize)
    #expect(index.memberships[mirror.id]?.workspaceName == "Updated workspace")
    catalog.projects.removeFirst()
    index.update(catalog: catalog, canonicalize: normalize)
    #expect(index.memberships.isEmpty)
  }

  @Test
  func catalogWithoutWorkspacesDoesNotResolvePaths() {
    let catalog = Catalog(projects: [
      Project(name: "source", rootPath: "/src", worktrees: [Worktree(name: "main", path: "/src")])
    ])
    var index = WorkspaceMembershipIndex()
    var calls = 0
    index.update(catalog: catalog) { path in
      calls += 1
      return path
    }
    #expect(calls == 0)
    #expect(index.memberships.isEmpty)
  }

  @Test
  func duplicateMembershipUsesCatalogOrderIncludingArchivedChildren() {
    var child = Worktree(name: "app", path: "/ws/app")
    child.archived = true
    let first = Project(name: "first", rootPath: "/ws", worktrees: [child], isWorkspace: true)
    let second = Project(
      name: "second", rootPath: "/other", worktrees: [Worktree(name: "app", path: child.path)],
      isWorkspace: true)
    var catalog = Catalog(projects: [first, second])
    var index = WorkspaceMembershipIndex()
    index.update(catalog: catalog, canonicalize: { $0 })
    #expect(index.memberships[child.id]?.projectID == first.id)
    catalog.projects.reverse()
    index.update(catalog: catalog, canonicalize: { $0 })
    #expect(index.memberships[child.id]?.projectID == second.id)
  }

  @Test
  func rootsDoNotMatchAndChangedPathsRemoveMembership() {
    let root = Worktree(name: "root", path: "/ws")
    let child = Worktree(name: "app", path: "/ws/app")
    var catalog = Catalog(projects: [
      Project(name: "ws", rootPath: "/ws", worktrees: [root, child], isWorkspace: true)
    ])
    var index = WorkspaceMembershipIndex()
    index.update(catalog: catalog, canonicalize: { $0 })
    #expect(index.memberships[root.id] == nil)
    #expect(index.memberships[child.id]?.worktreeID == child.id)
    catalog.projects[0].worktrees[1].path = "/ws"
    index.update(catalog: catalog, canonicalize: { $0 })
    #expect(index.memberships.isEmpty)
  }
}
