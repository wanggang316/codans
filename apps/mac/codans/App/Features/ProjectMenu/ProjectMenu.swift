import CodansCore
import Foundation

/// A project as a project menu row shows it. Snapshotted when the menu's
/// dialog or sheet opens.
struct ProjectMenuOption: Equatable, Identifiable {
  let id: ProjectID
  let name: String
  /// The project's icon and color, drawn with the sidebar's rules
  /// (`ProjectIconView`).
  let icon: ProjectIcon?
  let color: ProjectColor?
  /// Glyph for a project with no icon, or whose custom icon file is gone.
  let defaultSymbol: String
  /// A git project offers a new worktree or a branch. A folder or a
  /// workspace has one place to work.
  let isGit: Bool
  /// Lives on a Host, not on This Mac. A Recent row marks it.
  let isRemote: Bool
  /// Orders Recent. `nil` keeps the project out of Recent.
  let lastActiveAt: Date?

  init(
    id: ProjectID, name: String, icon: ProjectIcon?, color: ProjectColor?, kind: ProjectKind,
    isGit: Bool, isRemote: Bool, lastActiveAt: Date?
  ) {
    self.id = id
    self.name = name
    self.icon = icon
    self.color = color
    self.defaultSymbol = ProjectIconView.defaultSymbol(for: kind)
    self.isGit = isGit
    self.isRemote = isRemote
    self.lastActiveAt = lastActiveAt
  }

  init(_ project: Project) {
    self.init(
      id: project.id, name: project.name, icon: project.icon, color: project.color, kind: project.kind,
      isGit: project.supportsWorktrees && !project.isWorkspace, isRemote: project.hostID != nil,
      lastActiveAt: project.lastActiveAt)
  }
}

/// The sections of a project menu. Every project is in a group section; a
/// recently active one is also in Recent.
struct ProjectMenu: Equatable {
  struct Section: Equatable, Identifiable {
    let id: String
    let title: String
    let projects: [ProjectMenuOption]
  }

  /// Recent shows only above this many projects; it holds this many.
  static let recentLimit = 3

  /// The projects with the latest activity, newest first. Empty when the
  /// menu has `recentLimit` projects or fewer.
  let recent: [ProjectMenuOption]
  let sections: [Section]

  /// The New Agent dialog's menu: every project in the catalog. One
  /// "Projects" section, or one section per Host in sidebar Host order when
  /// the sidebar shows the Host level. Filters and collapsed Hosts do not
  /// apply.
  init(_ catalog: Catalog) {
    let projects = catalog.projects
    recent = Self.recent(in: projects.map(ProjectMenuOption.init))
    guard let groups = catalog.unfilteredSidebarHostGroups else {
      sections = [Self.projectsSection(projects.map(ProjectMenuOption.init))]
      return
    }
    sections = groups.map { group in
      Section(
        id: SidebarOutlineModel.hostNodeID(group.host), title: group.displayName,
        projects: group.projects.map(ProjectMenuOption.init))
    }
  }

  /// A menu of the given projects only, in their order: Recent over them
  /// and one "Projects" section. The caller filters first, so a project it
  /// leaves out is in no section.
  init(projects: [ProjectMenuOption]) {
    recent = Self.recent(in: projects)
    sections = [Self.projectsSection(projects)]
  }

  static let empty = ProjectMenu(Catalog())

  private static func recent(in projects: [ProjectMenuOption]) -> [ProjectMenuOption] {
    guard projects.count > recentLimit else { return [] }
    return
      projects
      .compactMap { project in project.lastActiveAt.map { (project, $0) } }
      .sorted { $0.1 > $1.1 }
      .prefix(recentLimit)
      .map(\.0)
  }

  private static func projectsSection(_ projects: [ProjectMenuOption]) -> Section {
    Section(id: "projects", title: "Projects", projects: projects)
  }
}
