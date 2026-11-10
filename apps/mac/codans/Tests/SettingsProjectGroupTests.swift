import CodansCore
import Foundation
import Testing

@testable import Codans

/// The Project sections of the Settings sidebar repeat the Host groups of the
/// main sidebar over every open Project (issue #498).
@MainActor
struct SettingsProjectGroupTests {
  private static func project(_ name: String, on host: HostRecord? = nil) -> Project {
    let root = Worktree(name: name, path: "/\(name)")
    return Project(
      name: name, rootPath: root.path, hostID: host?.id, remoteHost: host?.endpoint, worktrees: [root])
  }

  private static func titles(_ groups: [SettingsProjectGroup]) -> [String] { groups.map(\.title) }
  private static func names(_ groups: [SettingsProjectGroup]) -> [[String]] {
    groups.map { $0.projects.map(\.name) }
  }

  @Test
  func groupsUseHostDisplayNamesInHostListOrderWithThisMacFirst() {
    let named = HostRecord(address: "10.0.0.2", name: "Build box")
    let blank = HostRecord(address: "10.0.0.1", name: "  ")
    let catalog = Catalog(
      projects: [Self.project("zeta", on: blank), Self.project("local"), Self.project("alpha", on: named)],
      hosts: [named, blank])
    let groups = SettingsProjectGroup.groups(in: catalog)
    #expect(Self.titles(groups) == [HostRecord.thisMacName, "Build box", "10.0.0.1"])
    #expect(groups.map(\.host) == [.thisMac, .host(named.id), .host(blank.id)])
  }

  @Test
  func projectsKeepCatalogOrderNotAlphabetical() {
    let host = HostRecord(address: "box")
    let catalog = Catalog(
      projects: [
        Self.project("zeta"), Self.project("web", on: host), Self.project("alpha"), Self.project("api", on: host),
      ],
      hosts: [host])
    #expect(Self.names(SettingsProjectGroup.groups(in: catalog)) == [["zeta", "alpha"], ["web", "api"]])
  }

  @Test
  func sameAddressOrSameNameStaysTwoGroups() {
    let plain = HostRecord(address: "box", name: "Box")
    let otherUser = HostRecord(address: "box", username: "dev", name: "Box")
    let otherPort = HostRecord(address: "box", port: 2222)
    let catalog = Catalog(
      projects: [Self.project("a", on: plain), Self.project("b", on: otherUser), Self.project("c", on: otherPort)],
      hosts: [plain, otherUser, otherPort])
    let groups = SettingsProjectGroup.groups(in: catalog)
    #expect(Self.titles(groups) == ["Box", "Box", "box"])
    #expect(Self.names(groups) == [["a"], ["b"], ["c"]])
    #expect(Set(groups.map(\.id)).count == 3)
  }

  @Test
  func aLocalOnlyCatalogShowsOneProjectsSection() {
    let catalog = Catalog(projects: [Self.project("b"), Self.project("a")], hosts: [HostRecord(address: "box")])
    let groups = SettingsProjectGroup.groups(in: catalog)
    #expect(Self.titles(groups) == ["Projects"])
    #expect(Self.names(groups) == [["b", "a"]])
    #expect(SettingsProjectGroup.groups(in: Catalog()).isEmpty)
  }

  @Test
  func aRemoteOnlyCatalogHasNoThisMacGroup() {
    let host = HostRecord(address: "box")
    let unused = HostRecord(address: "idle")
    let catalog = Catalog(projects: [Self.project("api", on: host)], hosts: [unused, host])
    #expect(SettingsProjectGroup.groups(in: catalog).map(\.host) == [.host(host.id)])
  }

  @Test
  func filtersAndCollapsedHostsDoNotHideProjects() {
    let host = HostRecord(address: "box")
    var catalog = Catalog(projects: [Self.project("local"), Self.project("api", on: host)], hosts: [host])
    catalog.sidebarFilter = .remote
    catalog.activeTagFilter = .tags([TagID()])
    catalog.collapsedSidebarHosts = [.thisMac, .host(host.id)]
    #expect(Self.names(SettingsProjectGroup.groups(in: catalog)) == [["local"], ["api"]])
  }

  @Test
  func renamingAHostChangesTheTitle() {
    var host = HostRecord(address: "box")
    var catalog = Catalog(projects: [Self.project("api", on: host)], hosts: [host])
    #expect(Self.titles(SettingsProjectGroup.groups(in: catalog)) == ["box"])
    host.name = "Renamed"
    catalog.hosts = [host]
    #expect(Self.titles(SettingsProjectGroup.groups(in: catalog)) == ["Renamed"])
  }
}
