import ArgumentParser
import Foundation
import CodansCore
import CodansIPC
import CodansKit

/// `codans <project|worktree|tab|pane> show` — one entity, with the facts
/// `tree` folds into a line. `pane show` reads the catalog (containers,
/// labels, agent, focus); `pane info` asks the terminal daemon instead.

struct ProjectShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Describe a project: paths, git root, selection, worktree counts."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Project id, name, or 'current'.")
  var project: String = "current"

  func run() async throws {
    await CommandRunner.run {
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
    abstract: "Describe a worktree: path, branch, project, selection, tab count."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Worktree id, name, branch, or 'current'.")
  var worktree: String = "current"

  func run() async throws {
    await CommandRunner.run {
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
      ("tabs", "\(d.tabCount)"),
      ("selected tab", d.selectedTabID ?? "-"),
    ]
  }
}

struct TabShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Describe a tab: title, handle, containers, focused pane, pane ids."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Tab id, t<n> handle, title, or 'current'.")
  var tab: String = "current"

  func run() async throws {
    await CommandRunner.run {
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
      ("worktree", d.worktreeID),
      ("project", d.projectID),
      ("selected", d.isSelected ? "yes" : "no"),
      ("focused pane", d.focusedPaneID ?? "-"),
      ("panes", d.paneIDs.isEmpty ? "(none)" : d.paneIDs.joined(separator: ", ")),
    ]
  }
}

struct PaneShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Describe a pane from the catalog: containers, cwd, labels, agent, focus.",
    discussion: """
      Reads what Codans knows about the pane (its tab / worktree / project,
      handle, labels, the agent it runs, whether it is focused and live).
      `codans pane info` asks the pane's terminal daemon instead.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Pane id, p<n> handle, @label, or 'current'.")
  var pane: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      let description: IPC.PaneDescription = try await client.call(
        .hierarchyDescribePane, params: IPC.DescribeRequest(id: uuid))
      try Renderer.emit(KeyValueRenderable(description, lines: Self.lines), mode: globals.renderMode)
    }
  }

  private static func lines(_ d: IPC.PaneDescription) -> [(String, String)] {
    [
      ("pane", d.id + (d.handle.map { "  (\($0))" } ?? "")),
      ("cwd", d.workingDirectory),
      ("command", d.initialCommand ?? "(default shell)"),
      ("labels", d.labels.isEmpty ? "-" : d.labels.map { "@\($0)" }.joined(separator: " ")),
      ("agent", d.agent ?? "-"),
      ("session", d.agentSessionID ?? "-"),
      ("tab", d.tabID),
      ("worktree", d.worktreeID),
      ("project", d.projectID),
      ("focused", d.isFocused ? "yes" : "no"),
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
