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
          selectedTabID: worktree.selectedTabID?.description,
          tabCount: worktree.tabs.count
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
    for project in catalog.projects {
      for worktree in project.worktrees {
        guard let tab = worktree.tabs.first(where: { $0.id.raw == req.id }) else { continue }
        handleRegistry.sync(with: catalog)
        let handle = handleRegistry.snapshot().tabs[tab.id.description].map { "t\($0)" }
        return Self.encodeDescription(
          IPC.TabDescription(
            id: tab.id.description,
            handle: handle,
            projectID: project.id.description,
            worktreeID: worktree.id.description,
            title: tab.name ?? tab.cachedDisplayTitle,
            name: tab.name,
            icon: tab.icon,
            isSelected: worktree.selectedTabID == tab.id,
            focusedPaneID: tab.splitTree.zoomed?.description,
            paneIDs: tab.panes.map(\.id.description)
          ))
      }
    }
    return .failed(.notFound(kind: "tab", id: req.id.uuidString))
  }

  public func describePane(_ params: JSONValue) async -> RouterOutcome {
    await Task.yield()
    guard let req = try? params.decoded(as: IPC.DescribeRequest.self) else {
      return .failed(.invalidParams(message: "describePane requires {id}", path: nil))
    }
    let catalog = manager.catalog
    for project in catalog.projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs {
          guard let pane = tab.panes.first(where: { $0.id.raw == req.id }) else { continue }
          handleRegistry.sync(with: catalog)
          let handle = handleRegistry.snapshot().panes[pane.id.description].map { "p\($0)" }
          let live = overlayLivePaneDirectories(in: [pane])[0]
          return Self.encodeDescription(
            IPC.PaneDescription(
              id: pane.id.description,
              handle: handle,
              projectID: project.id.description,
              worktreeID: worktree.id.description,
              tabID: tab.id.description,
              workingDirectory: live.workingDirectory,
              initialCommand: pane.initialCommand,
              labels: pane.labels.sorted(),
              agent: pane.agentKind?.rawValue,
              agentSessionID: pane.agentSessionID,
              isLive: runtimeProbe(pane.id) != nil,
              isFocused: tab.splitTree.zoomed == pane.id
            ))
        }
      }
    }
    return .failed(.notFound(kind: "pane", id: req.id.uuidString))
  }

  private static func encodeDescription<T: Encodable>(_ description: T) -> RouterOutcome {
    do {
      return .unary(try JSONValue.encoded(description))
    } catch {
      return .failed(.internal("encode description: \(error)"))
    }
  }
}
