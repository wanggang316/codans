import CodansCore
import CodansIPC
import Foundation

// Output shapes of `codans tree`, `codans project list`, and the
// `<entity> show` verbs. They live here, not in the `codans-cli` executable,
// so CodansKitTests can assert the text and JSON a command prints.

public struct HierarchyTreeRenderable: Encodable, CustomStringConvertible {
  public let projects: [Project]
  /// Stable short handles from the app. Text mode prints them in place of
  /// the positional index (`Tab t3:` / `Pane p7:`) so agents can copy a
  /// selector that survives reordering; nil (older app) falls back to the
  /// positional numbering. JSON mode carries them as `handle` next to the
  /// UUID (null from an older app).
  public let handles: IPC.TargetHandles?
  /// Resolves each Project's Host name. Empty from an older app.
  public let hosts: [HostRecord]

  public init(projects: [Project], handles: IPC.TargetHandles?, hosts: [HostRecord]) {
    self.projects = projects
    self.handles = handles
    self.hosts = hosts
  }

  private enum Key: String, CodingKey { case projects }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(
      projects.map { HierarchyProjectDTO(project: $0, handles: handles, hosts: hosts) }, forKey: .projects)
  }

  public var description: String {
    guard !projects.isEmpty else { return "(no projects)" }
    var lines: [String] = []
    for (projectIndex, project) in projects.enumerated() {
      let isLastProject = projectIndex == projects.count - 1
      // Only the non-default kinds are labelled: a git repo is the common
      // case and reads cleaner bare.
      let kindSuffix = project.kind == .gitRepo ? "" : "  [\(project.kind.rawValue)]"
      lines.append("\(project.name)  \(project.id)\(kindSuffix)")
      lines.append("  host: \(Self.label(for: IPC.HostRef(project: project, hosts: hosts)))")
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

        for (tabIndex, tab) in worktree.tabs.enumerated() {
          let selectedTab = tab.id == worktree.selectedTabID ? "*" : " "
          let title = tab.name ?? tab.cachedDisplayTitle ?? "untitled"
          let tabLabel = handles?.tabs[tab.id.raw.uuidString].map { "t\($0)" } ?? "\(tabIndex + 1)"

          lines.append("\(indent)      [\(selectedTab)] Tab \(tabLabel): \(title)  \(tab.id)")

          for (paneIndex, pane) in tab.panes.enumerated() {
            let labels = pane.labels.sorted()
            let labelSuffix = labels.isEmpty ? "" : "  @\(labels.joined(separator: ",@"))"
            let paneLabel = handles?.panes[pane.id.raw.uuidString].map { "p\($0)" } ?? "\(paneIndex + 1)"
            lines.append("\(indent)            Pane \(paneLabel): \(pane.workingDirectory)  \(pane.id)\(labelSuffix)")
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
  public static func rows(of project: Project) -> [(worktree: Worktree, depth: Int)] {
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

  /// `name  id`, or the name alone for This Mac.
  public static func label(for host: IPC.HostRef) -> String {
    host.id.map { "\(host.name)  \($0)" } ?? host.name
  }

  private static func label(for ref: IPC.WorkspaceGroupRef) -> String {
    switch ref.role {
    case .groupTerminal: return "  (group \(ref.name))"
    case .reference: return "  (project in \(ref.name))"
    case .member: return "  (member of \(ref.name))"
    }
  }
}

public struct HierarchyProjectDTO: Encodable {
  public let id: String
  public let name: String
  public let rootPath: String
  public let gitRoot: String?
  /// `git_repo` | `dir` | `server` | `workspace` — `ProjectKind` raw values.
  public let kind: String
  /// `{id, name}` of the Project's Host; `id` is null for This Mac.
  public let host: IPC.HostRef
  public let selectedWorktreeID: String?
  public let worktrees: [HierarchyWorktreeDTO]

  public init(project: Project, handles: IPC.TargetHandles?, hosts: [HostRecord]) {
    self.id = project.id.description
    self.name = project.name
    self.rootPath = project.rootPath
    self.gitRoot = project.gitRoot
    self.kind = project.kind.rawValue
    self.host = IPC.HostRef(project: project, hosts: hosts)
    self.selectedWorktreeID = project.selectedWorktreeID?.description
    self.worktrees = HierarchyTreeRenderable.rows(of: project)
      .map { HierarchyWorktreeDTO(worktree: $0.worktree, project: project, handles: handles) }
  }
}

public struct HierarchyWorktreeDTO: Encodable {
  public let id: String
  public let name: String
  public let path: String
  public let branch: String?
  /// Repository root for a workspace child checkout; null otherwise (the
  /// Project's `gitRoot` applies).
  public let sourceGitRoot: String?
  /// `{id, name, role}` for a workspace row (`role`: `groupTerminal`,
  /// `reference`, or `member`); null otherwise.
  public let workspaceGroup: WorkspaceGroupDTO?
  public let selectedTabID: String?
  public let tabs: [HierarchyTabDTO]

  public struct WorkspaceGroupDTO: Encodable {
    public let id: String
    public let name: String
    public let role: String
  }

  public init(worktree: Worktree, project: Project, handles: IPC.TargetHandles?) {
    self.id = worktree.id.description
    self.name = worktree.name
    self.path = worktree.path
    self.branch = worktree.branch
    self.sourceGitRoot = worktree.sourceGitRoot
    self.workspaceGroup = IPC.WorkspaceGroupRef(worktree: worktree, in: project).map {
      WorkspaceGroupDTO(id: $0.id.description, name: $0.name, role: $0.role.rawValue)
    }
    self.selectedTabID = worktree.selectedTabID?.description
    self.tabs = worktree.tabs.map { HierarchyTabDTO(tab: $0, handles: handles) }
  }
}

public struct HierarchyTabDTO: Encodable {
  public let id: String
  /// `t<n>` selector, the same one the text tree prints.
  public let handle: String?
  public let name: String?
  public let cachedDisplayTitle: String?
  public let panes: [HierarchyPaneDTO]

  public init(tab: Tab, handles: IPC.TargetHandles?) {
    self.id = tab.id.description
    self.handle = handles?.tabs[tab.id.raw.uuidString].map { "t\($0)" }
    self.name = tab.name
    self.cachedDisplayTitle = tab.cachedDisplayTitle
    self.panes = tab.panes.map { HierarchyPaneDTO(pane: $0, handles: handles) }
  }
}

public struct HierarchyPaneDTO: Encodable {
  public let id: String
  /// `p<n>` selector, the same one the text tree prints.
  public let handle: String?
  public let workingDirectory: String
  public let labels: [String]

  public init(pane: Pane, handles: IPC.TargetHandles?) {
    self.id = pane.id.description
    self.handle = handles?.panes[pane.id.raw.uuidString].map { "p\($0)" }
    self.workingDirectory = pane.workingDirectory
    self.labels = pane.labels.sorted()
  }
}

public struct ProjectListRenderable: Encodable, CustomStringConvertible {
  public let projects: [Project]

  public init(projects: [Project]) {
    self.projects = projects
  }

  private enum Key: String, CodingKey { case projects }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(projects.map(ProjectDTO.init(project:)), forKey: .projects)
  }

  public var description: String {
    projects.isEmpty
      ? "(no projects)"
      : projects.map { "\($0.id)  \($0.name)  \($0.rootPath)" }.joined(separator: "\n")
  }
}

public struct ProjectDTO: Encodable {
  public let id: String
  public let name: String
  public let rootPath: String
  public let gitRoot: String?
  /// `git_repo` | `dir` | `server` | `workspace` — `ProjectKind` raw values.
  public let kind: String
  public let selectedWorktreeID: String?

  public init(project: Project) {
    self.id = project.id.description
    self.name = project.name
    self.rootPath = project.rootPath
    self.gitRoot = project.gitRoot
    self.kind = project.kind.rawValue
    self.selectedWorktreeID = project.selectedWorktreeID?.description
  }
}

/// JSON is the wire description as-is; text is aligned `key: value` rows.
public struct KeyValueRenderable<T: Encodable>: Encodable, CustomStringConvertible {
  public let value: T
  public let lines: (T) -> [(String, String)]

  public init(_ value: T, lines: @escaping (T) -> [(String, String)]) {
    self.value = value
    self.lines = lines
  }

  public func encode(to encoder: Encoder) throws {
    try value.encode(to: encoder)
  }

  public var description: String {
    let rows = lines(value)
    let width = (rows.map(\.0.count).max() ?? 0) + 1
    return rows.map { key, value in
      (key + ":").padding(toLength: width, withPad: " ", startingAt: 0) + " " + value
    }.joined(separator: "\n")
  }
}

/// Rows of `codans project show`.
public enum ProjectShowLines {
  public static func lines(_ d: IPC.ProjectDescription) -> [(String, String)] {
    [
      ("project", d.id),
      ("name", d.name + (d.name == d.canonicalName ? "" : " (folder: \(d.canonicalName))")),
      ("root", d.rootPath),
      ("git root", d.gitRoot ?? "(none: folder project)"),
      ("host", d.host.map(HierarchyTreeRenderable.label(for:)) ?? d.remoteHost ?? "-"),
      ("selected", d.isSelected ? "yes" : "no"),
      ("worktrees", "\(d.worktreeCount) active, \(d.archivedWorktreeCount) archived"),
      ("selected worktree", d.selectedWorktreeID ?? "-"),
      ("tags", d.tagIDs.isEmpty ? "-" : d.tagIDs.joined(separator: ", ")),
    ]
  }
}
