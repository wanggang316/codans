import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

struct TreeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tree",
    abstract: "List projects, worktrees, panes, and tabs.",
    discussion: """
      Use 'codans tree' as the first discovery command. It prints the full hierarchy so
      you do not have to walk projects, worktrees, panes, and tabs one command at
      a time. Each Tab line carries the id of the session it holds.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Restrict output to one project id, name, or 'current'.")
  var project: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
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

  func locatePane(_ paneID: PaneID) -> PanePath? {
    for project in projects {
      for worktree in project.worktrees where worktree.panes.contains(where: { $0.id == paneID }) {
        return PanePath(projectID: project.id, worktreeID: worktree.id, paneID: paneID)
      }
    }
    return nil
  }

  func locateTab(_ tabID: TabID) -> TabPath? {
    locateTab { $0.id == tabID }
  }

  func locateContent(_ contentID: ContentID) -> TabPath? {
    locateTab { $0.content.id == contentID }
  }

  /// Resolves a session reference whose flavour the caller does not know:
  /// the server hands back a Content, Tab or Pane id depending on the
  /// alias shape (`current`, `@label`, `t<n>`, `p<n>`). A Pane stands for
  /// its selected Tab.
  func locateSession(_ uuid: UUID) -> TabPath? {
    if let path = locateContent(ContentID(raw: uuid)) { return path }
    if let path = locateTab(TabID(raw: uuid)) { return path }
    for project in projects {
      for worktree in project.worktrees {
        if let pane = worktree.pane(PaneID(raw: uuid)), let tab = pane.selectedTab {
          return TabPath(
            projectID: project.id, worktreeID: worktree.id, paneID: pane.id, tabID: tab.id,
            contentID: tab.content.id)
        }
      }
    }
    return nil
  }

  private func locateTab(where predicate: (Tab) -> Bool) -> TabPath? {
    for project in projects {
      for worktree in project.worktrees {
        for pane in worktree.panes {
          if let tab = pane.tabs.first(where: predicate) {
            return TabPath(
              projectID: project.id, worktreeID: worktree.id, paneID: pane.id, tabID: tab.id,
              contentID: tab.content.id)
          }
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

/// A Tab and the session it holds, with its containers.
struct TabPath: Sendable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let paneID: PaneID
  let tabID: TabID
  let contentID: ContentID
}

/// A layout leaf with its containers.
struct PanePath: Sendable {
  let projectID: ProjectID
  let worktreeID: WorktreeID
  let paneID: PaneID
}

struct HierarchyTreeRenderable: Encodable, CustomStringConvertible {
  let projects: [Project]
  /// Stable short handles from the app. Text mode prints them in place of
  /// the positional index (`Pane p7:` / `Tab t3:`) so agents can copy a
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
      // Only the non-default kinds are labelled: a git repo is the common
      // case and reads cleaner bare.
      let kindSuffix = project.kind == .gitRepo ? "" : "  [\(project.kind.rawValue)]"
      lines.append("\(project.name)  \(project.id)\(kindSuffix)")
      lines.append("  path: \(project.rootPath)")

      for (worktreeIndex, row) in Self.rows(of: project).enumerated() {
        let worktree = row.worktree
        let indent = String(repeating: "  ", count: row.depth)
        let selectedWorktree = worktree.id == project.selectedWorktreeID ? "*" : " "
        let branch = worktree.branch ?? "no branch"
        let pinned = worktree.isPinned ? " pinned" : ""
        let group = IPC.WorkspaceGroupRef(worktree: worktree, in: project).map { Self.label(for: $0) } ?? ""

        lines.append(
          "\(indent)  [\(selectedWorktree)] Worktree \(worktreeIndex + 1): \(worktree.name)  [\(branch)]\(pinned)\(group)  \(worktree.id)"
        )
        lines.append("\(indent)      path: \(worktree.path)")

        for (paneIndex, pane) in worktree.panesInLayoutOrder.enumerated() {
          let focusedPane = pane.id == worktree.focusedPaneID ? "*" : " "
          let paneLabel = handles?.panes[pane.id.raw.uuidString].map { "p\($0)" } ?? "\(paneIndex + 1)"
          lines.append("\(indent)      [\(focusedPane)] Pane \(paneLabel):  \(pane.id)")

          for (tabIndex, tab) in pane.tabs.enumerated() {
            let selectedTab = tab.id == pane.selectedTabID ? "*" : " "
            let title = tab.name ?? tab.cachedDisplayTitle ?? "untitled"
            let tabLabel = handles?.tabs[tab.id.raw.uuidString].map { "t\($0)" } ?? "\(tabIndex + 1)"
            let terminal = tab.content.terminal
            let labels = terminal?.labels.sorted() ?? []
            let labelSuffix = labels.isEmpty ? "" : "  @\(labels.joined(separator: ",@"))"
            let cwd = terminal.map { "  \($0.workingDirectory)" } ?? ""
            lines.append(
              "\(indent)          [\(selectedTab)] Tab \(tabLabel): \(title)  \(tab.id)  content \(tab.content.id)\(cwd)\(labelSuffix)"
            )
          }
        }
      }

      if !isLastProject {
        lines.append("")
      }
    }
    return lines.joined(separator: "\n")
  }

  /// Unarchived rows in display order. A workspace nests each group's
  /// rows under its group row (`default` first); rows without a group
  /// follow at the top level.
  static func rows(of project: Project) -> [(worktree: Worktree, depth: Int)] {
    let live = project.worktrees.filter { !$0.archived }
    guard project.isWorkspace, !project.workspaceGroups.isEmpty else { return live.map { ($0, 0) } }
    let groups =
      project.workspaceGroups.filter { $0.kind == .default } + project.workspaceGroups.filter { $0.kind != .default }
    var rows: [(worktree: Worktree, depth: Int)] = []
    var placed = Set<WorktreeID>()
    for group in groups {
      let inGroup = live.filter { $0.workspaceSlot?.groupID == group.id }
      for worktree in inGroup where worktree.workspaceSlot?.role == .groupTerminal {
        rows.append((worktree, 0))
      }
      for worktree in inGroup where worktree.workspaceSlot?.role != .groupTerminal {
        rows.append((worktree, 1))
      }
      placed.formUnion(inGroup.map(\.id))
    }
    rows += live.filter { !placed.contains($0.id) }.map { ($0, 0) }
    return rows
  }

  private static func label(for ref: IPC.WorkspaceGroupRef) -> String {
    switch ref.role {
    case .groupTerminal: return "  (group \(ref.name))"
    case .reference: return "  (project in \(ref.name))"
    case .member: return "  (member of \(ref.name))"
    }
  }
}

struct HierarchyProjectDTO: Encodable {
  let id: String
  let name: String
  let rootPath: String
  let gitRoot: String?
  /// `git_repo` | `dir` | `server` | `workspace` — `ProjectKind` raw values.
  let kind: String
  let selectedWorktreeID: String?
  let worktrees: [HierarchyWorktreeDTO]

  init(project: Project, handles: IPC.TargetHandles?) {
    self.id = project.id.description
    self.name = project.name
    self.rootPath = project.rootPath
    self.gitRoot = project.gitRoot
    self.kind = project.kind.rawValue
    self.selectedWorktreeID = project.selectedWorktreeID?.description
    self.worktrees = HierarchyTreeRenderable.rows(of: project)
      .map { HierarchyWorktreeDTO(worktree: $0.worktree, project: project, handles: handles) }
  }
}

struct HierarchyWorktreeDTO: Encodable {
  let id: String
  let name: String
  let path: String
  let branch: String?
  /// Repository root for a workspace child checkout; null otherwise (the
  /// Project's `gitRoot` applies).
  let sourceGitRoot: String?
  /// `{id, name, role}` for a workspace row (`role`: `groupTerminal`,
  /// `reference`, or `member`); null otherwise.
  let workspaceGroup: WorkspaceGroupDTO?
  let focusedPaneID: String?
  /// The focused Pane's selected Tab.
  let selectedTabID: String?
  let panes: [HierarchyPaneDTO]

  struct WorkspaceGroupDTO: Encodable {
    let id: String
    let name: String
    let role: String
  }

  init(worktree: Worktree, project: Project, handles: IPC.TargetHandles?) {
    self.id = worktree.id.description
    self.name = worktree.name
    self.path = worktree.path
    self.branch = worktree.branch
    self.sourceGitRoot = worktree.sourceGitRoot
    self.workspaceGroup = IPC.WorkspaceGroupRef(worktree: worktree, in: project).map {
      WorkspaceGroupDTO(id: $0.id.description, name: $0.name, role: $0.role.rawValue)
    }
    self.focusedPaneID = worktree.focusedPaneID?.description
    self.selectedTabID = worktree.focusedPane?.selectedTabID?.description
    self.panes = worktree.panesInLayoutOrder.map {
      HierarchyPaneDTO(pane: $0, isFocused: $0.id == worktree.focusedPaneID, handles: handles)
    }
  }
}

struct HierarchyPaneDTO: Encodable {
  let id: String
  /// `p<n>` selector, the same one the text tree prints.
  let handle: String?
  let selectedTabID: String?
  let isFocused: Bool
  let tabs: [HierarchyTabDTO]

  init(pane: Pane, isFocused: Bool, handles: IPC.TargetHandles?) {
    self.id = pane.id.description
    self.handle = handles?.panes[pane.id.raw.uuidString].map { "p\($0)" }
    self.selectedTabID = pane.selectedTabID?.description
    self.isFocused = isFocused
    self.tabs = pane.tabs.map {
      HierarchyTabDTO(tab: $0, isSelected: $0.id == pane.selectedTabID, handles: handles)
    }
  }
}

struct HierarchyTabDTO: Encodable {
  let id: String
  /// `t<n>` selector, the same one the text tree prints.
  let handle: String?
  let name: String?
  let cachedDisplayTitle: String?
  let contentID: String
  /// `ContentKind` raw value.
  let kind: String
  let isSelected: Bool
  let workingDirectory: String?
  let labels: [String]
  let agent: String?

  init(tab: Tab, isSelected: Bool, handles: IPC.TargetHandles?) {
    self.id = tab.id.description
    self.handle = handles?.tabs[tab.id.raw.uuidString].map { "t\($0)" }
    self.name = tab.name
    self.cachedDisplayTitle = tab.cachedDisplayTitle
    self.contentID = tab.content.id.description
    self.kind = tab.content.state.kind.rawValue
    self.isSelected = isSelected
    let terminal = tab.content.terminal
    self.workingDirectory = terminal?.workingDirectory
    self.labels = terminal?.labels.sorted() ?? []
    self.agent = terminal?.agentKind?.rawValue
  }
}

extension Worktree {
  /// Panes as the layout shows them, left-to-right / top-to-bottom — the
  /// order `p<n>` handles are issued in; a Pane missing from the tree
  /// (never, by invariant) trails in array order.
  var panesInLayoutOrder: [Pane] {
    let leaves = splitTree.leaves()
    let seen = Set(leaves)
    return leaves.compactMap { pane($0) } + panes.filter { !seen.contains($0.id) }
  }
}
