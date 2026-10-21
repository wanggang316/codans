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
          selectedTabID: worktree.focusedPane?.selectedTabID?.description,
          tabCount: worktree.allTabs.count,
          focusedPaneID: worktree.focusedPaneID?.description,
          paneCount: worktree.panes.count
        ))
    }
    return .failed(.notFound(kind: "worktree", id: req.id.uuidString))
  }

  public func describeTab(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: IPC.DescribeRequest.self) else {
      return .failed(.invalidParams(message: "describeTab requires {id}", path: nil))
    }
    let catalog = manager.catalog
    // A Tab id, or a session id (its Tab).
    guard let tabID = catalog.tab(TabID(raw: req.id)).map(\.id) ?? catalog.tabID(forContent: ContentID(raw: req.id)),
      let address = catalog.address(forTab: tabID),
      let worktree = catalog.projects.first(where: { $0.id == address.projectID })?
        .worktrees.first(where: { $0.id == address.worktreeID }),
      let pane = worktree.pane(address.paneID),
      let tab = pane.tab(tabID)
    else {
      return .failed(.notFound(kind: "tab", id: req.id.uuidString))
    }
    handleRegistry.sync(with: catalog)
    let handle = handleRegistry.handle(forTab: tab.id).map { "t\($0)" }
    return Self.encodeDescription(
      IPC.TabDescription(
        id: tab.id.description,
        handle: handle,
        projectID: address.projectID.description,
        worktreeID: address.worktreeID.description,
        paneID: pane.id.description,
        contentID: tab.contentID.description,
        title: tab.name ?? tab.cachedDisplayTitle,
        name: tab.name,
        icon: tab.icon,
        color: tab.color,
        isSelected: pane.selectedTabID == tab.id,
        focusedPaneID: worktree.focusedPaneID?.description,
        paneIDs: [pane.id.description]
      ))
  }

  public func describePane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: IPC.DescribeRequest.self) else {
      return .failed(.invalidParams(message: "describePane requires {id}", path: nil))
    }
    let catalog = manager.catalog
    // A session id, a Tab id (its session), or a Pane id (its selected
    // Tab's session).
    let contentID: ContentID? =
      catalog.content(ContentID(raw: req.id)).map(\.id)
      ?? catalog.contentID(forTab: TabID(raw: req.id))
      ?? catalog.pane(PaneID(raw: req.id))?.selectedTab?.contentID
    guard let contentID, let address = catalog.address(forContent: contentID),
      let worktree = catalog.projects.first(where: { $0.id == address.projectID })?
        .worktrees.first(where: { $0.id == address.worktreeID }),
      let pane = worktree.pane(address.paneID),
      let tab = pane.tab(address.tabID)
    else {
      return .failed(.notFound(kind: "pane", id: req.id.uuidString))
    }
    handleRegistry.sync(with: catalog)
    let handle = handleRegistry.handle(forTab: tab.id).map { "t\($0)" }
    let live = overlayLiveDirectories(in: [tab])[0].content.terminal
    return Self.encodeDescription(
      IPC.PaneDescription(
        id: contentID.description,
        handle: handle,
        projectID: address.projectID.description,
        worktreeID: address.worktreeID.description,
        tabID: tab.id.description,
        contentID: contentID.description,
        workingDirectory: live?.workingDirectory ?? "",
        initialCommand: tab.content.terminal?.initialCommand,
        labels: (tab.content.terminal?.labels ?? []).sorted(),
        agent: tab.content.terminal?.agentKind?.rawValue,
        agentSessionID: tab.content.terminal?.agentSessionID,
        isLive: runtimeProbe(contentID) != nil,
        isFocused: worktree.focusedPaneID == pane.id && pane.selectedTabID == tab.id
      ))
  }

  private static func encodeDescription<T: Encodable>(_ description: T) -> RouterOutcome {
    do {
      return .unary(try JSONValue.encoded(description))
    } catch {
      return .failed(.internal("encode description: \(error)"))
    }
  }
}
