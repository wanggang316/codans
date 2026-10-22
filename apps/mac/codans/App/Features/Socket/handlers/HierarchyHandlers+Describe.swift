import CodansCore
import CodansIPC
import Foundation

/// `hierarchy.describe*` — one entity by id, with the facts `tree` folds
/// into a line: containers, selection / focus, handle, live directory.
/// Backs `codans <project|worktree|tab|pane> show`.
extension HierarchyHandlers {
  public func describeProject(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: IPC.DescribeRequest.self) else {
      return .failed(.invalidParams(message: "describeProject requires {id}", path: nil))
    }
    let catalog = manager.catalog
    guard let project = catalog.projects.first(where: { $0.id.raw == req.id }) else {
      return .failed(.notFound(kind: "project", id: req.id.uuidString))
    }
    return Self.encodeDescription(
      IPC.ProjectDescription(
        id: project.id.description,
        name: project.name,
        canonicalName: project.canonicalName,
        rootPath: project.rootPath,
        gitRoot: project.gitRoot,
        remoteHost: project.remoteHost?.alias,
        isSelected: catalog.selectedProjectID == project.id,
        selectedWorktreeID: project.selectedWorktreeID?.description,
        worktreeCount: project.worktrees.filter { !$0.archived }.count,
        archivedWorktreeCount: project.worktrees.filter(\.archived).count,
        tagIDs: project.tagIDs.map(\.description).sorted()
      ))
  }

  public func describeWorktree(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: IPC.DescribeRequest.self) else {
      return .failed(.invalidParams(message: "describeWorktree requires {id}", path: nil))
    }
    for project in manager.catalog.projects {
      guard let worktree = project.worktrees.first(where: { $0.id.raw == req.id }) else { continue }
      return Self.encodeDescription(
        IPC.WorktreeDescription(
          id: worktree.id.description,
          projectID: project.id.description,
          projectName: project.name,
          name: worktree.name,
          path: worktree.path,
          branch: worktree.branch,
          isArchived: worktree.archived,
          isPinned: worktree.isPinned,
          isSelected: project.selectedWorktreeID == worktree.id,
          focusedPaneID: worktree.focusedPaneID?.description,
          paneCount: worktree.panes.count,
          workspaceGroup: IPC.WorkspaceGroupRef(worktree: worktree, in: project)
        ))
    }
    return .failed(.notFound(kind: "worktree", id: req.id.uuidString))
  }

  /// `hierarchy.describeTab` — a Tab id, or a Content id (its Tab), or a
  /// Pane id (its selected Tab).
  public func describeTab(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: IPC.DescribeRequest.self) else {
      return .failed(.invalidParams(message: "describeTab requires {id}", path: nil))
    }
    guard let tabID = convert(req.id, to: .tab).map({ TabID(raw: $0.id) }),
      let description = tabDescription(tabID)
    else {
      return .failed(.notFound(kind: "tab", id: req.id.uuidString))
    }
    return Self.encodeDescription(description)
  }

  /// `hierarchy.describePane` — a Pane id, or a Tab / Content id (its Pane).
  public func describePane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: IPC.DescribeRequest.self) else {
      return .failed(.invalidParams(message: "describePane requires {id}", path: nil))
    }
    guard let paneID = convert(req.id, to: .pane).map({ PaneID(raw: $0.id) }),
      let description = paneDescription(paneID)
    else {
      return .failed(.notFound(kind: "pane", id: req.id.uuidString))
    }
    return Self.encodeDescription(description)
  }

  /// The wire description of one Tab; shared by `describeTab` and the
  /// rows of `listTabs`.
  func tabDescription(_ tabID: TabID) -> IPC.TabDescription? {
    let catalog = manager.catalog
    guard let address = catalog.address(forTab: tabID),
      let pane = catalog.pane(address.paneID),
      let tab = pane.tab(tabID)
    else { return nil }
    handleRegistry.sync(with: catalog)
    let terminal = tab.content.terminal
    return IPC.TabDescription(
      id: tab.id.description,
      handle: handleRegistry.handle(forTab: tab.id).map { "t\($0)" },
      projectID: address.projectID.description,
      worktreeID: address.worktreeID.description,
      paneID: pane.id.description,
      contentID: tab.contentID.description,
      title: tab.name ?? tab.cachedDisplayTitle,
      name: tab.name,
      icon: tab.icon,
      color: tab.color,
      isSelected: pane.selectedTabID == tab.id,
      workingDirectory: overlayLiveDirectories(in: [tab])[0].content.terminal?.workingDirectory,
      labels: (terminal?.labels ?? []).sorted(),
      agent: terminal?.agentKind?.rawValue,
      agentSessionID: terminal?.agentSessionID,
      isLive: runtimeProbe(tab.contentID) != nil
    )
  }

  /// The wire description of one Pane; shared by `describePane` and the
  /// rows of `listPanes`.
  func paneDescription(_ paneID: PaneID) -> IPC.PaneDescription? {
    let catalog = manager.catalog
    guard let address = catalog.address(forPane: paneID),
      let worktree = catalog.projects.first(where: { $0.id == address.projectID })?
        .worktrees.first(where: { $0.id == address.worktreeID }),
      let pane = worktree.pane(paneID)
    else { return nil }
    handleRegistry.sync(with: catalog)
    return IPC.PaneDescription(
      id: pane.id.description,
      handle: handleRegistry.handle(forPane: pane.id).map { "p\($0)" },
      projectID: address.projectID.description,
      worktreeID: address.worktreeID.description,
      selectedTabID: pane.selectedTabID?.description,
      tabIDs: pane.tabIDs.map(\.description),
      isFocused: worktree.focusedPaneID == pane.id
    )
  }

  private static func encodeDescription<T: Encodable>(_ description: T) -> RouterOutcome {
    do {
      return .unary(try JSONValue.encoded(description))
    } catch {
      return .failed(.internal("encode description: \(error)"))
    }
  }
}
