import ArgumentParser
import Foundation
import TouchCodeCore
import TouchCodeIPC
import tcKit

struct PaneList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List panes for a tab."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id or 'current'.")
  var worktree: String = "current"
  @Option(name: .long, help: "Tab id or 'current'.")
  var tab: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      let tabUUID = try await AliasResolver.resolve(tab, kind: .tab, client: client)
      struct Params: Codable {
        let tabID: TabID
        let worktreeID: WorktreeID
        let projectID: ProjectID
      }
      let result: PaneListPayload = try await client.call(
        .hierarchyListPanes,
        params: Params(
          tabID: TabID(raw: tabUUID),
          worktreeID: WorktreeID(raw: worktreeUUID),
          projectID: ProjectID(raw: projectUUID)
        )
      )
      try Renderer.emit(PaneListRenderable(panes: result.panes), mode: globals.renderMode)
    }
  }
}

struct PaneCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pane",
    abstract: "Create, focus, close, label, read, reset, and send panes.",
    subcommands: [
      PaneNew.self,
      PaneFocus.self,
      PaneClose.self,
      PaneLabel.self,
      PaneReset.self,
      SendCommand.self,
      SendKeyCommand.self,
      ReadCommand.self,
      CaptureCommand.self,
    ]
  )
}

struct PaneNew: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "new",
    abstract: "Create a pane, optionally with an initial command."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(parsing: .remaining, help: "Initial command. Omit for the default shell.")
  var command: [String] = []
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id or 'current'.")
  var worktree: String = "current"
  @Option(name: .long, help: "Tab id or 'current'.")
  var tab: String = "current"
  @Option(name: .long, help: "Working directory. Defaults to $PWD.")
  var cwd: String?
  @Option(name: .long, parsing: .upToNextOption, help: "Initial labels.")
  var label: [String] = []

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      let tabUUID = try await AliasResolver.resolve(tab, kind: .tab, client: client)
      let initialCommand = command.isEmpty ? nil : command.joined(separator: " ")
      struct Params: Codable {
        let projectID: ProjectID
        let worktreeID: WorktreeID
        let tabID: TabID
        let workingDirectory: String
        let initialCommand: String?
        let labels: [String]
      }
      struct Result: Codable { let id: PaneID }
      let result: Result = try await client.call(
        .hierarchyOpenPane,
        params: Params(
          projectID: ProjectID(raw: projectUUID),
          worktreeID: WorktreeID(raw: worktreeUUID),
          tabID: TabID(raw: tabUUID),
          workingDirectory: PathResolver.absolute(cwd),
          initialCommand: initialCommand,
          labels: label
        )
      )
      try Renderer.emitObject(
        ["id": result.id.description],
        mode: globals.renderMode
      ) { _ in
        "created pane \(result.id.description)"
      }
    }
  }
}

struct PaneLocatorArgs: ParsableArguments {
  @Argument(help: "Pane id, @label, or 'current'.")
  var pane: String
  @Option(name: .long, help: "Project id, name, or 'current'. Usually inferred from the pane id.")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id or 'current'. Usually inferred from the pane id.")
  var worktree: String = "current"
  @Option(name: .long, help: "Tab id or 'current'. Usually inferred from the pane id.")
  var tab: String = "current"
}

struct PaneFocus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "focus",
    abstract: "Focus a pane."
  )

  @OptionGroup var globals: GlobalOptions
  @OptionGroup var args: PaneLocatorArgs

  func run() async throws {
    await PaneLocatorFlow.run(
      globals: globals,
      args: args,
      method: .hierarchyFocusPane,
      verbLabel: "focused"
    )
  }
}

struct PaneClose: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a pane and kill its zmx daemon.",
    discussion: """
      Sends `.kill` to the pane's zmx daemon (bounded ≤ 2 s wait for the
      daemon's control socket to vanish), drops the persisted session
      catalog entry, and removes the pane from the in-memory hierarchy.

      Distinct from the UI X-button path, which detaches the libghostty
      surface so a future attach can resume the same daemon. Use this
      verb when you want the daemon gone.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @OptionGroup var args: PaneLocatorArgs

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let paneUUID = try await AliasResolver.resolve(args.pane, kind: .pane, client: client)
      // Best-effort locator: when the caller didn't override the
      // project/worktree/tab triple, send only the paneID and let the
      // handler walk the catalog server-side. Saves a round-trip on the
      // common `tc pane close <id>` shape.
      let request: IPC.PaneCloseRequest
      if args.project != "current" || args.worktree != "current" || args.tab != "current" {
        let path = try await PaneLocatorFlow.resolvePanePath(
          paneUUID: paneUUID,
          args: args,
          client: client
        )
        request = IPC.PaneCloseRequest(
          paneID: path.paneID,
          tabID: path.tabID,
          worktreeID: path.worktreeID,
          projectID: path.projectID
        )
      } else {
        request = IPC.PaneCloseRequest(paneID: PaneID(raw: paneUUID))
      }
      let response: IPC.PaneCloseResponse = try await client.call(.paneClose, params: request)
      if response.closed {
        try Renderer.emit(
          IDMessage(
            id: paneUUID.uuidString,
            message: "closed pane \(paneUUID.uuidString)"
          ),
          mode: globals.renderMode
        )
      } else {
        throw CLIError(
          code: .notFound,
          message: "no pane found for \(paneUUID.uuidString)"
        )
      }
    }
  }
}

struct PaneReset: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "reset",
    abstract: "Reset a pane's terminal state.",
    discussion: """
      Routes through libghostty's reset binding action — the same path the
      context-menu "Reset Terminal" item uses. Clears scrollback and
      reinitialises the terminal without disturbing the child process.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Pane id, @label, or 'current'.")
  var pane: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      struct Params: Codable {
        let paneID: PaneID
      }
      _ = try await client.callRaw(
        .terminalResetPane,
        params: Params(paneID: PaneID(raw: uuid))
      )
      try Renderer.emit(
        IDMessage(id: uuid.uuidString, message: "reset pane \(uuid.uuidString)"),
        mode: globals.renderMode
      )
    }
  }
}

struct PaneLabel: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "label",
    abstract: "Add labels to a pane."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Pane id, @label, or 'current'.")
  var pane: String
  @Argument(help: "Labels.")
  var labels: [String]
  @Flag(name: .long, help: "Replace the existing labels.")
  var replace: Bool = false

  func run() async throws {
    await CommandRunner.run {
      guard !labels.isEmpty else {
        throw CLIError(code: .userError, message: "specify at least one label")
      }
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(pane, kind: .pane, client: client)
      struct Params: Codable {
        let id: PaneID
        let labels: [String]
        let replace: Bool
      }
      _ = try await client.callRaw(
        .hierarchySetPaneLabels,
        params: Params(id: PaneID(raw: uuid), labels: labels, replace: replace)
      )
      try Renderer.emitObject(
        ["id": uuid.uuidString, "labels": labels],
        mode: globals.renderMode
      ) { _ in
        "labeled pane \(uuid.uuidString)"
      }
    }
  }
}

struct PaneLocatorBody: Codable, Sendable {
  let id: PaneID
  let tabID: TabID
  let worktreeID: WorktreeID
  let projectID: ProjectID
}

enum PaneLocatorFlow {
  static func run(
    globals: GlobalOptions,
    args: PaneLocatorArgs,
    method: IPC.Method,
    verbLabel: String
  ) async {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let paneUUID = try await AliasResolver.resolve(args.pane, kind: .pane, client: client)
      let path = try await resolvePanePath(
        paneUUID: paneUUID,
        args: args,
        client: client
      )
      _ = try await client.callRaw(
        method,
        params: PaneLocatorBody(
          id: path.paneID,
          tabID: path.tabID,
          worktreeID: path.worktreeID,
          projectID: path.projectID
        )
      )
      try Renderer.emit(
        IDMessage(id: paneUUID.uuidString, message: "\(verbLabel) pane \(paneUUID.uuidString)"),
        mode: globals.renderMode
      )
    }
  }

  static func resolvePanePath(
    paneUUID: UUID,
    args: PaneLocatorArgs,
    client: RPCClient
  ) async throws -> PanePath {
    try await resolvePanePath(
      paneUUID: paneUUID,
      project: args.project,
      worktree: args.worktree,
      tab: args.tab,
      client: client
    )
  }

  static func resolvePanePath(
    paneUUID: UUID,
    project: String,
    worktree: String,
    tab: String,
    client: RPCClient
  ) async throws -> PanePath {
    if project != "current" || worktree != "current" || tab != "current" {
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      let tabUUID = try await AliasResolver.resolve(tab, kind: .tab, client: client)
      return PanePath(
        projectID: ProjectID(raw: projectUUID),
        worktreeID: WorktreeID(raw: worktreeUUID),
        tabID: TabID(raw: tabUUID),
        paneID: PaneID(raw: paneUUID)
      )
    }

    let paneID = PaneID(raw: paneUUID)
    let tree = try await HierarchyTree.load(client: client)
    guard let path = tree.locatePane(paneID) else {
      throw CLIError(code: .notFound, message: "pane \(paneUUID.uuidString) not found")
    }
    return path
  }
}

struct PaneListPayload: Codable { let panes: [Pane] }

struct PaneListRenderable: Encodable, CustomStringConvertible {
  let panes: [Pane]
  private enum Key: String, CodingKey { case panes }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(panes.map(PaneDTO.init(pane:)), forKey: .panes)
  }

  var description: String {
    panes.isEmpty
      ? "(no panes)"
      : panes.map { pane in
        let labels = pane.labels.sorted().joined(separator: ",")
        let suffix = labels.isEmpty ? "" : " [\(labels)]"
        return "\(pane.id)  \(pane.workingDirectory)\(suffix)"
      }.joined(separator: "\n")
  }
}

struct PaneDTO: Encodable {
  let id: String
  let workingDirectory: String
  let labels: [String]

  init(pane: Pane) {
    self.id = pane.id.description
    self.workingDirectory = pane.workingDirectory
    self.labels = pane.labels.sorted()
  }
}
