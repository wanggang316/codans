import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

/// `codans tab …` — the session verbs. A Tab holds one Content (a terminal
/// session), so acting on the Tab is acting on its session. Every Tab
/// position accepts a Tab, Content, or Pane id (a Pane means its selected
/// Tab), a `t<n>` / `p<n>` handle, an `@label`, a title, or `current`.
struct TabCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tab",
    abstract: "Drive tabs and their sessions: list, show, create, focus, rename, close, send, read, label, reset.",
    subcommands: [
      TabList.self,
      TabShow.self,
      TabNew.self,
      TabFocus.self,
      TabRename.self,
      TabClose.self,
      TabSend.self,
      TabSendKey.self,
      TabCapture.self,
      TabRead.self,
      TabInfo.self,
      TabLabel.self,
      TabReset.self,
      MovedTabSwitch.self,
    ]
  )
}

private let tabArgumentHelp = ArgumentHelp(
  "Tab: an id (tab, content, or pane → its selected tab), t<n>, @label, title, or 'current'.")

struct TabList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List the tabs of a worktree, or of one pane's strip."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id, name, branch, or 'current'.")
  var worktree: String = "current"
  @Option(name: .long, help: "Only this pane's strip: an id (pane, tab, or content), p<n>, or 'current'.")
  var pane: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let resolved = try await ScopeResolver.worktree(
        project: project, worktree: worktree, pane: pane, client: client)
      struct Params: Codable {
        let worktreeID: WorktreeID
        let projectID: ProjectID
        let paneID: UUID?
      }
      let result: TabListPayload = try await client.call(
        .hierarchyListTabs,
        params: Params(
          worktreeID: resolved.scope.worktreeID, projectID: resolved.scope.projectID, paneID: resolved.paneID?.raw)
      )
      try Renderer.emit(TabListRenderable(tabs: result.tabs), mode: globals.renderMode)
    }
  }
}

struct TabNew: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "new",
    abstract: "Open a new tab, optionally running a command.",
    discussion: """
      The tab opens at the end of a pane's strip — the focused pane unless
      --pane names one — and its terminal starts at once. A worktree with no
      pane gets its first one. Prints the new tab's id; the JSON result also
      carries its handle, pane, and content ids.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(parsing: .remaining, help: "Initial command. Omit for the default shell.")
  var command: [String] = []
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id, name, branch, or 'current'.")
  var worktree: String = "current"
  @Option(name: .long, help: "Pane whose strip takes the tab: an id (pane, tab, or content), p<n>, or 'current'.")
  var pane: String?
  @Option(name: .long, help: "Tab name.")
  var name: String?
  @Option(name: .long, help: "Working directory. Defaults to $PWD.")
  var cwd: String?
  @Option(name: .long, parsing: .upToNextOption, help: "Initial labels.")
  var label: [String] = []

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let resolved = try await ScopeResolver.worktree(
        project: project, worktree: worktree, pane: pane, client: client)
      struct Params: Codable {
        let projectID: ProjectID
        let worktreeID: WorktreeID
        let paneID: UUID?
        let name: String?
        let workingDirectory: String
        let initialCommand: String?
        let labels: [String]
      }
      struct Result: Codable {
        let id: TabID
        let handle: String?
        let paneID: PaneID
        let contentID: ContentID
      }
      let result: Result = try await client.call(
        .hierarchyCreateTab,
        params: Params(
          projectID: resolved.scope.projectID,
          worktreeID: resolved.scope.worktreeID,
          paneID: resolved.paneID?.raw,
          name: name,
          workingDirectory: PathResolver.absolute(cwd),
          initialCommand: command.isEmpty ? nil : command.joined(separator: " "),
          labels: label
        )
      )
      try Renderer.emitObject(
        [
          "id": result.id.description,
          "handle": result.handle.map { $0 as Any } ?? NSNull(),
          "paneID": result.paneID.description,
          "contentID": result.contentID.description,
        ],
        mode: globals.renderMode
      ) { _ in
        result.id.description
      }
    }
  }
}

struct TabFocus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "focus",
    abstract: "Select a tab and give its pane the keyboard."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: tabArgumentHelp)
  var tab: String

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let target = try await TabTarget.resolve(.tab(tab), client: client)
      try await TabTarget.activate(target, client: client)
      try Renderer.emitObject(target.jsonFields, mode: globals.renderMode) { _ in
        "focused tab \(target.tabID)"
      }
    }
  }
}

struct TabRename: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rename",
    abstract: "Set a tab's title, or clear it to follow the shell again.",
    discussion: """
      With a name the tab keeps that title; without one (or with an empty
      string) the user title is cleared and the tab shows the live title the
      shell reports, as a new tab does.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: tabArgumentHelp)
  var tab: String
  @Argument(help: "New title; omit or pass '' to clear.")
  var name: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let tabID = TabID(raw: try await AliasResolver.resolve(tab, kind: .tab, client: client))
      struct Params: Codable {
        let id: TabID
        let name: String?
      }
      let result: RenameResult = try await client.call(
        .hierarchyRenameTab, params: Params(id: tabID, name: name))
      try Renderer.emitObject(
        ["id": result.id, "name": result.name.map { $0 as Any } ?? NSNull()],
        mode: globals.renderMode
      ) { _ in
        result.name.map { "renamed tab \(result.id) to \($0)" } ?? "cleared title of tab \(result.id)"
      }
    }
  }
}

struct TabClose: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a tab and end its session.",
    discussion: """
      Kills the tab's terminal daemon (waiting up to 2 s for it to exit),
      drops its persisted session entry, and removes the tab. Closing the
      last tab of a pane closes the pane. No confirmation is asked.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: tabArgumentHelp)
  var tab: String

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let tabID = TabID(raw: try await AliasResolver.resolve(tab, kind: .tab, client: client))
      struct Params: Codable { let id: TabID }
      struct Result: Codable {
        let id: TabID
        let contentID: ContentID
      }
      let result: Result = try await client.call(.hierarchyCloseTab, params: Params(id: tabID))
      try Renderer.emitObject(
        ["id": result.id.description, "contentID": result.contentID.description],
        mode: globals.renderMode
      ) { _ in
        "closed tab \(result.id)"
      }
    }
  }
}

struct TabLabel: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "label",
    abstract: "Add labels to a tab's session (target it later as @label)."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: tabArgumentHelp)
  var tab: String
  @Argument(help: "Labels.")
  var labels: [String]
  @Flag(name: .long, help: "Replace the existing labels.")
  var replace: Bool = false

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      guard !labels.isEmpty else {
        throw CLIError(code: .userError, message: "specify at least one label")
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let target = try await TabTarget.resolve(.tab(tab), client: client)
      struct Params: Codable {
        let contentID: ContentID
        let labels: [String]
        let replace: Bool
      }
      _ = try await client.callRaw(
        .hierarchySetTabLabels,
        params: Params(contentID: target.contentID, labels: labels, replace: replace)
      )
      var object = target.jsonFields
      object["labels"] = labels
      try Renderer.emitObject(object, mode: globals.renderMode) { _ in
        "labeled tab \(target.tabID)"
      }
    }
  }
}

struct TabReset: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "reset",
    abstract: "Reset a tab's terminal state.",
    discussion: """
      Routes through libghostty's reset binding action — the same path the
      context-menu "Reset Terminal" item uses. Clears scrollback and
      reinitialises the terminal without disturbing the child process.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: tabArgumentHelp)
  var tab: String = "current"

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let target = try await TabTarget.resolve(.tab(tab), client: client)
      struct Params: Codable { let contentID: ContentID }
      _ = try await client.callRaw(.terminalResetPane, params: Params(contentID: target.contentID))
      try Renderer.emitObject(target.jsonFields, mode: globals.renderMode) { _ in
        "reset tab \(target.tabID)"
      }
    }
  }
}

struct TabInfo: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "info",
    abstract: "Probe a tab's terminal daemon for shell pid, pwd, and (when available) cursor + modes.",
    discussion: """
      Round-trips through the tab's zmx daemon rather than the catalog,
      so a stale catalog row does not leak past as live truth. The
      daemon's Info payload carries pid + cwd; cursor and modes are
      reported as null — use `tab read --raw` and parse the vt-format
      dump for those.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: tabArgumentHelp)
  var tab: String = "current"

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let target = try await TabTarget.resolve(.tab(tab), client: client)
      let response: IPC.TabInfoResponse = try await client.call(
        .tabInfo, params: IPC.TabInfoRequest(contentID: target.contentID))
      try Renderer.emit(TabInfoRenderable(target: target, response: response), mode: globals.renderMode)
    }
  }
}

struct TabInfoRenderable: Encodable, CustomStringConvertible {
  let target: TabTarget
  let response: IPC.TabInfoResponse
  private enum Key: String, CodingKey {
    case tabID, contentID, paneID, shellPid, pwd, cursor, modes
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(target.tabID.description, forKey: .tabID)
    try container.encode(target.contentID.description, forKey: .contentID)
    try container.encode(target.paneID.description, forKey: .paneID)
    try container.encode(response.shellPid, forKey: .shellPid)
    try container.encode(response.pwd, forKey: .pwd)
    try container.encode(response.cursor, forKey: .cursor)
    try container.encode(response.modes, forKey: .modes)
  }

  var description: String {
    var lines: [String] = []
    lines.append("tab:     \(target.tabID)")
    lines.append("content: \(target.contentID)")
    lines.append("shell:   pid=\(response.shellPid)")
    lines.append("pwd:     \(response.pwd)")
    if let cursor = response.cursor {
      lines.append("cursor:  row=\(cursor.row) col=\(cursor.col)")
    }
    if let modes = response.modes, !modes.isEmpty {
      let pairs = modes.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value ? "on" : "off")" }
        .joined(separator: " ")
      lines.append("modes:   \(pairs)")
    }
    return lines.joined(separator: "\n")
  }
}

struct TabRead: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "read",
    abstract: "Read serialized terminal state from a tab's terminal daemon.",
    discussion: """
      Returns the daemon's serializeTerminalState dump. Pass --raw for the
      vt-format dump (ANSI escapes, cursor, modes, OSC 7 preserved);
      omit it for the plain-text dump. --tail N keeps the last N lines.
      --range is reserved for viewport / scrollback splitting; the daemon
      returns the full dump regardless of range.
      """
  )

  enum Range: String, ExpressibleByArgument, CaseIterable {
    case visible
    case scrollback
    case all
  }

  @OptionGroup var globals: GlobalOptions
  @Argument(help: tabArgumentHelp)
  var tab: String = "current"
  @Flag(name: .long, help: "Return the vt-format dump with ANSI escapes preserved.")
  var raw: Bool = false
  @Option(name: .long, help: "Keep only the last N newline-delimited lines.")
  var tail: Int?
  @Option(name: .long, help: "Range: visible, scrollback, or all (default).")
  var range: Range = .all

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      if let tail, tail <= 0 {
        throw CLIError(code: .userError, message: "--tail must be a positive integer")
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let target = try await TabTarget.resolve(.tab(tab), client: client)
      let wireRange: IPC.TabReadRange =
        switch range {
        case .visible: .visible
        case .scrollback: .scrollback
        case .all: .all
        }
      let response: IPC.TabReadResponse = try await client.call(
        .tabRead,
        params: IPC.TabReadRequest(contentID: target.contentID, range: wireRange, tail: tail, raw: raw)
      )
      // --raw dumps the literal byte stream so callers can grep for ANSI
      // codes; structured renderers (json) get the same content wrapped in
      // metadata.
      var object = target.jsonFields
      object["format"] = response.format.rawValue
      object["range"] = range.rawValue
      object["content"] = response.content
      try Renderer.emitObject(object, mode: globals.renderMode) { obj in
        obj["content"] as? String ?? ""
      }
    }
  }
}

struct TabListPayload: Codable { let tabs: [IPC.TabDescription] }

struct TabListRenderable: Encodable, CustomStringConvertible {
  let tabs: [IPC.TabDescription]
  private enum Key: String, CodingKey { case tabs }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(tabs, forKey: .tabs)
  }

  var description: String {
    tabs.isEmpty
      ? "(no tabs)"
      : tabs.map { tab in
        let selected = tab.isSelected ? "*" : " "
        let handle = tab.handle.map { "\($0)  " } ?? ""
        return "[\(selected)] \(handle)\(tab.title ?? "(untitled)")  \(tab.id)  content \(tab.contentID)"
      }
      .joined(separator: "\n")
  }
}
