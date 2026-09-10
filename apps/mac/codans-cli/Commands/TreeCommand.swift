import ArgumentParser
import Foundation
import CodansCore
import CodansIPC
import CodansKit

struct TreeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tree",
    abstract: "List projects, worktrees, tabs, and panes.",
    discussion: """
      Use 'codans tree' as the first discovery command. It prints the full hierarchy so
      you do not have to walk projects, worktrees, tabs, and panes one command at
      a time.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Restrict output to one project id, name, or 'current'.")
  var project: String?

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let tree = try await HierarchyTree.load(client: client, timeout: globals.rpcTimeout)
      let projects: [Project]
      if let project {
        let uuid = try await AliasResolver.resolve(project, kind: .project, client: client)
        projects = tree.projects.filter { $0.id.raw == uuid }
        if projects.isEmpty {
          throw CLIError(code: .notFound, message: "project \(uuid.uuidString) not found")
        }
      } else {
        projects = tree.projects
      }
      try Renderer.emit(
        HierarchyTreeRenderable(projects: projects, handles: tree.handles),
        mode: globals.renderMode
      )
    }
  }
}

struct HierarchyTree: Codable, Sendable {
  let projects: [Project]
  let handles: IPC.TargetHandles?

  static func load(client: RPCClient, timeout: Duration = .seconds(10)) async throws -> HierarchyTree {
    let payload: ProjectListPayload = try await client.call(
      .hierarchyListProjects,
      params: EmptyParams(),
      timeout: timeout
    )
    return HierarchyTree(projects: payload.projects, handles: payload.handles)
  }

  func locateWorktree(_ worktreeID: WorktreeID) -> WorktreePath? {
    for project in projects where project.worktrees.contains(where: { $0.id == worktreeID }) {
      return WorktreePath(projectID: project.id, worktreeID: worktreeID)
    }
    return nil
  }

  func locateTab(_ tabID: TabID) -> TabPath? {
    for project in projects {
      for worktree in project.worktrees where worktree.tabs.contains(where: { $0.id == tabID }) {
        return TabPath(projectID: project.id, worktreeID: worktree.id, tabID: tabID)
      }
    }
    return nil
  }

  func locatePane(_ paneID: PaneID) -> PanePath? {
    for project in projects {
      for worktree in project.worktrees {
        for tab in worktree.tabs where tab.panes.contains(where: { $0.id == paneID }) {
          return PanePath(projectID: project.id, worktreeID: worktree.id, tabID: tab.id, paneID: paneID)
        }
      }
    }
    return nil
  }
}

struct WorktreePath: Sendable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
}

struct TabPath: Sendable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
}

struct PanePath: Sendable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let tabID: TabID
  let paneID: PaneID
}

struct HierarchyTreeRenderable: Encodable, CustomStringConvertible {
  let projects: [Project]
  /// Stable short handles from the app. Text mode prints them in place of
  /// the positional index (`Tab t3:` / `Pane p7:`) so agents can copy a
  /// selector that survives reordering; nil (older app) falls back to the
  /// positional numbering. JSON mode carries them as `handle` next to the
  /// UUID (null from an older app).
  let handles: IPC.TargetHandles?

  private enum Key: String, CodingKey { case projects }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(
      projects.map { HierarchyProjectDTO(project: $0, handles: handles) }, forKey: .projects)
  }

  var description: String {
    guard !projects.isEmpty else { return "(no projects)" }
    var lines: [String] = []
    for (projectIndex, project) in projects.enumerated() {
      let isLastProject = projectIndex == projects.count - 1
      lines.append("\(project.name)  \(project.id)")
      lines.append("  path: \(project.rootPath)")

      let worktrees = project.worktrees.filter { !$0.archived }
      for (worktreeIndex, worktree) in worktrees.enumerated() {
        let selectedWorktree = worktree.id == project.selectedWorktreeID ? "*" : " "
        let branch = worktree.branch ?? "no branch"
        let pinned = worktree.isPinned ? " pinned" : ""

        lines.append(
          "  [\(selectedWorktree)] Worktree \(worktreeIndex + 1): \(worktree.name)  [\(branch)]\(pinned)  \(worktree.id)"
        )
        lines.append("      path: \(worktree.path)")

        for (tabIndex, tab) in worktree.tabs.enumerated() {
          let selectedTab = tab.id == worktree.selectedTabID ? "*" : " "
          let title = tab.name ?? tab.cachedDisplayTitle ?? "untitled"
          let tabLabel = handles?.tabs[tab.id.raw.uuidString].map { "t\($0)" } ?? "\(tabIndex + 1)"

          lines.append("      [\(selectedTab)] Tab \(tabLabel): \(title)  \(tab.id)")

          for (paneIndex, pane) in tab.panes.enumerated() {
            let labels = pane.labels.sorted()
            let labelSuffix = labels.isEmpty ? "" : "  @\(labels.joined(separator: ",@"))"
            let paneLabel = handles?.panes[pane.id.raw.uuidString].map { "p\($0)" } ?? "\(paneIndex + 1)"
            lines.append("            Pane \(paneLabel): \(pane.workingDirectory)  \(pane.id)\(labelSuffix)")
          }
        }
      }

      if !isLastProject {
        lines.append("")
      }
    }
    return lines.joined(separator: "\n")
  }
}

struct HierarchyProjectDTO: Encodable {
  let id: String
  let name: String
  let rootPath: String
  let gitRoot: String?
  let selectedWorktreeID: String?
  let worktrees: [HierarchyWorktreeDTO]

  init(project: Project, handles: IPC.TargetHandles?) {
    self.id = project.id.description
    self.name = project.name
    self.rootPath = project.rootPath
    self.gitRoot = project.gitRoot
    self.selectedWorktreeID = project.selectedWorktreeID?.description
    self.worktrees = project.worktrees.filter { !$0.archived }
      .map { HierarchyWorktreeDTO(worktree: $0, handles: handles) }
  }
}

struct HierarchyWorktreeDTO: Encodable {
  let id: String
  let name: String
  let path: String
  let branch: String?
  let selectedTabID: String?
  let tabs: [HierarchyTabDTO]

  init(worktree: Worktree, handles: IPC.TargetHandles?) {
    self.id = worktree.id.description
    self.name = worktree.name
    self.path = worktree.path
    self.branch = worktree.branch
    self.selectedTabID = worktree.selectedTabID?.description
    self.tabs = worktree.tabs.map { HierarchyTabDTO(tab: $0, handles: handles) }
  }
}

struct HierarchyTabDTO: Encodable {
  let id: String
  /// `t<n>` selector, the same one the text tree prints.
  let handle: String?
  let name: String?
  let cachedDisplayTitle: String?
  let panes: [HierarchyPaneDTO]

  init(tab: Tab, handles: IPC.TargetHandles?) {
    self.id = tab.id.description
    self.handle = handles?.tabs[tab.id.raw.uuidString].map { "t\($0)" }
    self.name = tab.name
    self.cachedDisplayTitle = tab.cachedDisplayTitle
    self.panes = tab.panes.map { HierarchyPaneDTO(pane: $0, handles: handles) }
  }
}

struct HierarchyPaneDTO: Encodable {
  let id: String
  /// `p<n>` selector, the same one the text tree prints.
  let handle: String?
  let workingDirectory: String
  let labels: [String]

  init(pane: Pane, handles: IPC.TargetHandles?) {
    self.id = pane.id.description
    self.handle = handles?.panes[pane.id.raw.uuidString].map { "p\($0)" }
    self.workingDirectory = pane.workingDirectory
    self.labels = pane.labels.sorted()
  }
}
