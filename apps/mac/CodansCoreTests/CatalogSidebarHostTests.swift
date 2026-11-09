import Foundation
import Testing

@testable import CodansCore

/// The sidebar's Host level (ADR 0002, decisions 2, 3, 7, 8): when it shows,
/// how Projects group under it, and how it changes the selection order.
struct CatalogSidebarHostTests {
  private let box = HostRecord(address: "box", username: "dev")
  private let mini = HostRecord(address: "mini", name: "Mac mini")

  private let localRoot = Worktree(name: "notes", path: "/notes")
  private let boxRoot = Worktree(name: "api", path: "/srv/api")
  private let miniRoot = Worktree(name: "web", path: "/srv/web")

  private var local: Project { Project(name: "notes", rootPath: "/notes", worktrees: [localRoot]) }

  private func remote(_ name: String, on host: HostRecord, root: Worktree) -> Project {
    Project(name: name, rootPath: root.path, hostID: host.id, remoteHost: host.endpoint, worktrees: [root])
  }

  /// Host list order is box, mini; Projects are listed mini, local, box.
  private var catalog: Catalog {
    Catalog(
      projects: [remote("web", on: mini, root: miniRoot), local, remote("api", on: box, root: boxRoot)],
      hosts: [box, mini])
  }

  @Test
  func onlyLocalProjectsHaveNoHostLevel() {
    let catalog = Catalog(projects: [local], hosts: [box])
    #expect(catalog.sidebarHostLevel == nil)
  }

  @Test
  func groupsListThisMacFirstThenHostListOrder() throws {
    let catalog = self.catalog
    let level = try #require(catalog.sidebarHostLevel)
    let groups = level.groups(catalog.sidebarProjects)
    #expect(groups.map(\.host) == [.thisMac, .host(box.id), .host(mini.id)])
    #expect(groups.map(\.displayName) == ["This Mac", "box", "Mac mini"])
    #expect(groups.map { $0.projects.map(\.name) } == [["notes"], ["api"], ["web"]])
    #expect(groups.allSatisfy { $0.isExpanded })
  }

  /// The unfiltered order ignores a collapsed Host and the sidebar filter:
  /// it lists every Project in Host order.
  @Test
  func sidebarOrderedProjectsGroupByHostIgnoringCollapseAndFilter() {
    var catalog = self.catalog
    catalog.collapsedSidebarHosts = [.host(box.id)]
    catalog.sidebarFilter = .workspace
    #expect(catalog.sidebarOrderedProjects.map(\.name) == ["notes", "api", "web"])
    #expect(Catalog(projects: [local]).sidebarOrderedProjects.map(\.name) == ["notes"])
  }

  @Test
  func aHostWithoutProjectsHasNoGroup() throws {
    let catalog = Catalog(projects: [local, remote("api", on: box, root: boxRoot)], hosts: [box, mini])
    let level = try #require(catalog.sidebarHostLevel)
    #expect(level.groups(catalog.sidebarProjects).map(\.host) == [.thisMac, .host(box.id)])
  }

  @Test
  func aRemoteOnlyCatalogStillListsThisMacFirst() throws {
    let catalog = Catalog(projects: [remote("api", on: box, root: boxRoot)], hosts: [box])
    let level = try #require(catalog.sidebarHostLevel)
    let groups = level.groups(catalog.sidebarProjects)
    #expect(groups.map(\.host) == [.thisMac, .host(box.id)])
    #expect(groups[0].projects.isEmpty)
    #expect(catalog.sidebarSelectionOrder.map(\.worktreeID) == [boxRoot.id])
  }

  @Test
  func anEmptyThisMacHidesUnderAFilter() throws {
    var catalog = Catalog(projects: [remote("api", on: box, root: boxRoot)], hosts: [box])
    catalog.sidebarFilter = .remote
    #expect(try #require(catalog.sidebarHostLevel).groups(catalog.sidebarProjects).map(\.host) == [.host(box.id)])

    catalog.sidebarFilter = .all
    let tag = TagID()
    catalog.projects[0].tagIDs = [tag]
    catalog.activeTagFilter = .tags([tag])
    #expect(try #require(catalog.sidebarHostLevel).groups(catalog.sidebarProjects).map(\.host) == [.host(box.id)])
  }

  @Test
  func filtersHideHostsWithoutMatchesButKeepTheLevel() throws {
    var catalog = self.catalog
    catalog.sidebarFilter = .remote
    let level = try #require(catalog.sidebarHostLevel)
    #expect(level.groups(catalog.sidebarProjects).map(\.host) == [.host(box.id), .host(mini.id)])

    catalog.sidebarFilter = .all
    let tag = TagID()
    catalog.projects[1].tagIDs = [tag]
    catalog.activeTagFilter = .tags([tag])
    #expect(catalog.sidebarHostLevel != nil)
    #expect(level.groups(catalog.sidebarProjects).map(\.host) == [.thisMac])
  }

  @Test
  func selectionOrderFollowsHostOrderAndSkipsClosedHosts() {
    var catalog = self.catalog
    #expect(catalog.sidebarSelectionOrder.map(\.worktreeID) == [localRoot.id, boxRoot.id, miniRoot.id])

    catalog.collapsedSidebarHosts = [.host(box.id)]
    #expect(catalog.sidebarSelectionOrder.map(\.worktreeID) == [localRoot.id, miniRoot.id])

    catalog.collapsedSidebarHosts = [.thisMac]
    #expect(catalog.sidebarSelectionOrder.map(\.worktreeID) == [boxRoot.id, miniRoot.id])
  }

  @Test
  func withoutAHostLevelTheCollapsedSetIsIgnored() {
    var catalog = Catalog(projects: [local])
    catalog.collapsedSidebarHosts = [.thisMac]
    #expect(catalog.sidebarSelectionOrder.map(\.worktreeID) == [localRoot.id])
  }

  @Test
  func collapsedHostsRoundTripAndRemovingAHostDropsIt() throws {
    var catalog = self.catalog
    catalog.collapsedSidebarHosts = [.thisMac, .host(box.id)]
    let data = try JSONEncoder().encode(catalog)
    let decoded = try JSONDecoder().decode(Catalog.self, from: data)
    #expect(decoded.collapsedSidebarHosts == [.thisMac, .host(box.id)])

    var unused = Catalog(projects: [local], hosts: [box])
    unused.collapsedSidebarHosts = [.host(box.id)]
    try unused.removeHost(id: box.id)
    #expect(unused.collapsedSidebarHosts.isEmpty)
  }

  @Test
  func anOpenCatalogOmitsTheCollapsedKey() throws {
    let data = try JSONEncoder().encode(catalog)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("collapsedSidebarHosts"))
  }
}
