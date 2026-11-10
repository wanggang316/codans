import CodansCore
import Foundation
import Testing

@testable import Codans

/// Settings → (a Workspace) → Projects → Add Project: the shared project menu
/// over the local git projects the Workspace does not list yet.
@MainActor
struct WorkspaceSettingsAddProjectMenuTests {
  private static func project(_ name: String, active: TimeInterval? = nil) -> Project {
    Project(
      name: name, rootPath: "/src/\(name)", gitRoot: "/src/\(name)",
      lastActiveAt: active.map { Date(timeIntervalSince1970: $0) })
  }

  private static func menu(_ projects: [Project], listed: Set<String> = []) -> ProjectMenu {
    ProjectGeneralSettingsView.workspaceAddProjectMenu(
      catalog: Catalog(projects: projects), listedGitRoots: listed)
  }

  @Test
  func hidesRecentUpToThreeCandidates() {
    let menu = Self.menu([Self.project("a", active: 3), Self.project("b", active: 1), Self.project("c", active: 2)])
    #expect(menu.recent.isEmpty)
    #expect(menu.sections.map(\.title) == ["Projects"])
    #expect(menu.sections.first?.projects.map(\.name) == ["a", "b", "c"])
  }

  @Test
  func listsThreeNewestCandidatesAboveThree() {
    let menu = Self.menu([
      Self.project("never"), Self.project("old", active: 1), Self.project("newest", active: 9),
      Self.project("mid", active: 5), Self.project("newer", active: 7),
    ])
    #expect(menu.recent.map(\.name) == ["newest", "newer", "mid"])
    #expect(menu.sections.first?.projects.map(\.name) == ["never", "old", "newest", "mid", "newer"])
  }

  @Test
  func leavesOutNonCandidatesBeforeComputingRecent() {
    let remote = Project(
      name: "remote", rootPath: "/src/remote", gitRoot: "/src/remote", hostID: HostID(),
      lastActiveAt: Date(timeIntervalSince1970: 20))
    let folder = Project(name: "folder", rootPath: "/src/folder", lastActiveAt: Date(timeIntervalSince1970: 19))
    let workspace = Project(
      name: "ws", rootPath: "/ws", gitRoot: "/ws", lastActiveAt: Date(timeIntervalSince1970: 18), isWorkspace: true)
    let menu = Self.menu(
      [
        remote, folder, workspace, Self.project("listed", active: 17),
        Self.project("a", active: 1), Self.project("b", active: 2), Self.project("c", active: 3),
      ],
      listed: ["/src/listed"])
    // Seven projects, three candidates: Recent stays hidden.
    #expect(menu.recent.isEmpty)
    #expect(menu.sections.first?.projects.map(\.name) == ["a", "b", "c"])
  }

  @Test
  func recentNeverHoldsAListedProject() {
    let menu = Self.menu(
      [
        Self.project("listed", active: 10), Self.project("a", active: 1), Self.project("b", active: 2),
        Self.project("c", active: 3), Self.project("d", active: 4),
      ],
      listed: ["/src/listed"])
    #expect(menu.recent.map(\.name) == ["d", "c", "b"])
    #expect(menu.sections.first?.projects.map(\.name) == ["a", "b", "c", "d"])
  }

  @Test
  func matchesAListedProjectThroughASymlinkedPath() throws {
    // A Workspace can record a source as `/var/...` while the project's git
    // root is `/private/var/...`: the same repository.
    let real = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
      .appendingPathComponent("sv-516-\(UUID().uuidString)")
    let link = real.deletingLastPathComponent().appendingPathComponent("link-\(real.lastPathComponent)")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer {
      try? FileManager.default.removeItem(at: link)
      try? FileManager.default.removeItem(at: real)
    }
    let project = Project(name: "api", rootPath: real.path, gitRoot: real.path)
    let menu = Self.menu([project, Self.project("other")], listed: [link.path])
    #expect(menu.sections.first?.projects.map(\.name) == ["other"])
  }

  @Test
  func rowsCarryTheProjectIconAndColor() {
    var project = Self.project("app")
    project.icon = .symbol("hammer")
    project.color = .red
    let option = Self.menu([project]).sections.first?.projects.first
    #expect(option?.icon == .symbol("hammer"))
    #expect(option?.color == .red)
    #expect(option?.isRemote == false)
  }
}
