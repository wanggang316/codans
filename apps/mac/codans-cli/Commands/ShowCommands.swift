import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

/// `codans <project|worktree|tab> show` — one entity, with the facts
/// `tree` folds into a line. `tab show` reads the catalog (containers,
/// labels, agent, selection); `tab info` asks the terminal daemon instead.

struct ProjectShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Describe a project: paths, git root, selection, worktree counts."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Project id, name, or 'current'.")
  var project: String = "current"

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(project, kind: .project, client: client)
      let description: IPC.ProjectDescription = try await client.call(
        .hierarchyDescribeProject, params: IPC.DescribeRequest(id: uuid))
      try Renderer.emit(KeyValueRenderable(description, lines: Self.lines), mode: globals.renderMode)
    }
  }

  private static func lines(_ d: IPC.ProjectDescription) -> [(String, String)] {
    [
      ("project", d.id),
      ("name", d.name + (d.name == d.canonicalName ? "" : " (folder: \(d.canonicalName))")),
      ("root", d.rootPath),
      ("git root", d.gitRoot ?? "(none: folder project)"),
      ("remote", d.remoteHost ?? "-"),
      ("selected", d.isSelected ? "yes" : "no"),
      ("worktrees", "\(d.worktreeCount) active, \(d.archivedWorktreeCount) archived"),
      ("selected worktree", d.selectedWorktreeID ?? "-"),
      ("tags", d.tagIDs.isEmpty ? "-" : d.tagIDs.joined(separator: ", ")),
    ]
  }
}

struct WorktreeShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Describe a worktree: path, branch, project, selection, panes."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Worktree id, name, branch, or 'current'.")
  var worktree: String = "current"

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      let description: IPC.WorktreeDescription = try await client.call(
        .hierarchyDescribeWorktree, params: IPC.DescribeRequest(id: uuid))
      try Renderer.emit(KeyValueRenderable(description, lines: Self.lines), mode: globals.renderMode)
    }
  }

  private static func lines(_ d: IPC.WorktreeDescription) -> [(String, String)] {
    [
      ("worktree", d.id),
      ("name", d.name),
      ("path", d.path),
      ("branch", d.branch ?? "(no branch)"),
      ("project", "\(d.projectName)  \(d.projectID)"),
      ("selected", d.isSelected ? "yes" : "no"),
      ("archived", d.isArchived ? "yes" : "no"),
      ("pinned", d.isPinned ? "yes" : "no"),
      ("panes", "\(d.paneCount)"),
      ("focused pane", d.focusedPaneID ?? "-"),
    ]
  }
}

struct TabShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Describe a tab from the catalog: handle, pane, content, chip, cwd, labels, agent.",
    discussion: """
      Reads what Codans knows about the tab (its pane and session ids,
      handle, title, color, labels, the agent it runs, whether it is
      selected and live). `tab info` asks the tab's terminal daemon instead.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Tab: an id (tab, content, or pane → its selected tab), t<n>, @label, title, or 'current'.")
  var tab: String = "current"

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(tab, kind: .tab, client: client)
      let description: IPC.TabDescription = try await client.call(
        .hierarchyDescribeTab, params: IPC.DescribeRequest(id: uuid))
      try Renderer.emit(KeyValueRenderable(description, lines: Self.lines), mode: globals.renderMode)
    }
  }

  private static func lines(_ d: IPC.TabDescription) -> [(String, String)] {
    [
      ("tab", d.id + (d.handle.map { "  (\($0))" } ?? "")),
      ("title", d.title ?? "(untitled)"),
      ("name", d.name ?? "(auto)"),
      ("icon", d.icon ?? "(auto)"),
      ("color", d.color?.rawValue ?? "(none)"),
      ("content", d.contentID),
      ("pane", d.paneID),
      ("worktree", d.worktreeID),
      ("project", d.projectID),
      ("cwd", d.workingDirectory ?? "-"),
      ("labels", d.labels.isEmpty ? "-" : d.labels.map { "@\($0)" }.joined(separator: " ")),
      ("agent", d.agent ?? "-"),
      ("session", d.agentSessionID ?? "-"),
      ("selected", d.isSelected ? "yes" : "no"),
      ("live", d.isLive ? "yes" : "no"),
    ]
  }
}

/// JSON is the wire description as-is; text is aligned `key: value` rows.
struct KeyValueRenderable<T: Encodable>: Encodable, CustomStringConvertible {
  let value: T
  let lines: (T) -> [(String, String)]

  init(_ value: T, lines: @escaping (T) -> [(String, String)]) {
    self.value = value
    self.lines = lines
  }

  func encode(to encoder: Encoder) throws {
    try value.encode(to: encoder)
  }

  var description: String {
    let rows = lines(value)
    let width = (rows.map(\.0.count).max() ?? 0) + 1
    return rows.map { key, value in
      (key + ":").padding(toLength: width, withPad: " ", startingAt: 0) + " " + value
    }.joined(separator: "\n")
  }
}
