import CodansCore

/// A row the user opened or closed. Only these changes animate in the
/// outline; every other change of the open state is instant (ADR 0007,
/// decision 2). The reducer sets it, so the outline does not have to guess
/// the intent from a change of catalog state.
struct SidebarExpansionToggle: Equatable {
  enum Target: Equatable {
    case host(SidebarHost)
    case project(ProjectID)
    case workspaceGroup(projectID: ProjectID, groupID: WorkspaceGroupID)
  }

  let target: Target
  /// Increases with each toggle, so a second toggle of the same row is a new
  /// value.
  let sequence: Int

  /// The outline node of the toggled row.
  var nodeID: String {
    switch target {
    case .host(let host): SidebarOutlineModel.hostNodeID(host)
    case .project(let projectID): SidebarOutlineModel.projectNodeID(projectID)
    case .workspaceGroup(let projectID, let groupID): SidebarOutlineModel.workspaceGroupNodeID(projectID, groupID)
    }
  }

  /// The toggle after `previous`.
  static func next(_ target: Target, after previous: Self?) -> Self {
    Self(target: target, sequence: (previous?.sequence ?? 0) + 1)
  }
}
