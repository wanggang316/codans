import Foundation
import Testing

@testable import CodansCore

struct WorkspaceMembershipIndexTests {
  private static let group = WorkspaceGroupID()

  private func member(_ name: String, path: String) -> Worktree {
    Worktree(name: name, path: path, workspaceSlot: WorkspaceSlot(groupID: Self.group, role: .member))
  }

  @Test
  func aliasesMatchAndUnrelatedChangesDoNotResolvePathsAgain() {
    let child = member("app", path: "/real/ws/app")
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
    #expect(initialCalls == 2)
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
    var child = member("app", path: "/ws/app")
    child.archived = true
    let first = Project(name: "first", rootPath: "/ws", worktrees: [child], isWorkspace: true)
    let second = Project(
      name: "second", rootPath: "/other", worktrees: [member("app", path: child.path)],
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
  func referencesAndGroupRowsGiveTheSourceMainRowNoMembership() {
    let groupRow = Worktree(
      name: "default", path: "/ws/default",
      workspaceSlot: WorkspaceSlot(groupID: Self.group, role: .groupTerminal))
    let reference = Worktree(
      name: "app", path: "/src/app", workspaceSlot: WorkspaceSlot(groupID: Self.group, role: .reference))
    let sourceMain = Worktree(name: "main", path: "/src/app")
    let catalog = Catalog(projects: [
      Project(name: "ws", rootPath: "/ws", worktrees: [groupRow, reference], isWorkspace: true),
      Project(name: "app", rootPath: "/src/app", gitRoot: "/src/app", worktrees: [sourceMain]),
    ])
    var index = WorkspaceMembershipIndex()
    index.update(catalog: catalog, canonicalize: { $0 })
    #expect(index.memberships.isEmpty)
  }

  @Test
  func slotChangesRebuildTheIndex() {
    let child = Worktree(name: "app", path: "/ws/app")
    var catalog = Catalog(projects: [
      Project(name: "ws", rootPath: "/ws", worktrees: [child], isWorkspace: true)
    ])
    var index = WorkspaceMembershipIndex()
    index.update(catalog: catalog, canonicalize: { $0 })
    #expect(index.memberships.isEmpty)

    catalog.projects[0].worktrees[0].workspaceSlot = WorkspaceSlot(groupID: Self.group, role: .member)
    index.update(catalog: catalog, canonicalize: { $0 })
    #expect(index.memberships[child.id]?.worktreeID == child.id)

    catalog.projects[0].worktrees[0].workspaceSlot = WorkspaceSlot(groupID: Self.group, role: .reference)
    index.update(catalog: catalog, canonicalize: { $0 })
    #expect(index.memberships.isEmpty)
  }
}
