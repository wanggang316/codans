import CodansCore

/// One Project section of the Settings sidebar. The sections repeat the Host
/// groups of the main sidebar (ADR 0002, ADR 0003) over every open Project:
/// the sidebar filters and collapsed Hosts do not apply here.
struct SettingsProjectGroup: Equatable, Identifiable {
  /// The Host the section stands for; `nil` for the single "Projects"
  /// section of a catalog with no Remote Project.
  let host: SidebarHost?
  let title: String
  let projects: [Project]

  var id: String {
    host.map(SidebarOutlineModel.hostNodeID) ?? "projects"
  }

  /// One "Projects" section while every Project is on This Mac; else one
  /// section per Host with a Project, This Mac first, then the Host list
  /// order. Projects keep the catalog order of the main sidebar.
  static func groups(in catalog: Catalog) -> [Self] {
    guard let hostGroups = catalog.unfilteredSidebarHostGroups else {
      return catalog.projects.isEmpty ? [] : [Self(host: nil, title: "Projects", projects: catalog.projects)]
    }
    return hostGroups.map { Self(host: $0.host, title: $0.displayName, projects: $0.projects) }
  }
}
