import ArgumentParser
import Foundation
import CodansCore
import CodansIPC
import CodansKit

struct TabList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List tabs for a worktree."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id or 'current'.")
  var worktree: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      struct Params: Codable {
        let worktreeID: WorktreeID
        let projectID: ProjectID
      }
      let result: TabListPayload = try await client.call(
        .hierarchyListTabs,
        params: Params(
          worktreeID: WorktreeID(raw: worktreeUUID),
          projectID: ProjectID(raw: projectUUID)
        )
      )
      try Renderer.emit(TabListRenderable(tabs: result.tabs), mode: globals.renderMode)
    }
  }
}

struct TabCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tab",
    abstract: "Create, switch, and close tabs.",
    subcommands: [
      TabNew.self,
      TabSwitch.self,
      TabClose.self,
    ]
  )
}

struct TabNew: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "new",
    abstract: "Create a tab."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Tab name.")
  var name: String?
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id or 'current'.")
  var worktree: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      struct Params: Codable {
        let projectID: ProjectID
        let worktreeID: WorktreeID
        let name: String?
      }
      struct Result: Codable { let id: TabID }
      let result: Result = try await client.call(
        .hierarchyCreateTab,
        params: Params(
          projectID: ProjectID(raw: projectUUID),
          worktreeID: WorktreeID(raw: worktreeUUID),
          name: name
        )
      )
      try Renderer.emitObject(
        ["id": result.id.description, "name": name ?? ""],
        mode: globals.renderMode
      ) { _ in
        "created tab \(result.id.description)"
      }
    }
  }
}

struct TabSwitch: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "switch",
    abstract: "Activate a tab."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Tab id, t<n> handle, or 'current'.")
  var tab: String

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(tab, kind: .tab, client: client)
      struct Params: Codable { let id: UUID }
      _ = try await client.callRaw(.hierarchyActivateTab, params: Params(id: uuid))
      try Renderer.emit(
        IDMessage(id: uuid.uuidString, message: "switched tab \(uuid.uuidString)"), mode: globals.renderMode)
    }
  }
}

struct TabClose: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "close",
    abstract: "Close a tab."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Tab id, t<n> handle, or 'current'.")
  var tab: String
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(name: .long, help: "Worktree id or 'current'.")
  var worktree: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      let tabUUID = try await AliasResolver.resolve(tab, kind: .tab, client: client)
      struct Params: Codable {
        let id: TabID
        let worktreeID: WorktreeID
        let projectID: ProjectID
      }
      _ = try await client.callRaw(
        .hierarchyCloseTab,
        params: Params(
          id: TabID(raw: tabUUID),
          worktreeID: WorktreeID(raw: worktreeUUID),
          projectID: ProjectID(raw: projectUUID)
        )
      )
      try Renderer.emit(
        IDMessage(id: tabUUID.uuidString, message: "closed tab \(tabUUID.uuidString)"), mode: globals.renderMode)
    }
  }
}

struct TabListPayload: Codable { let tabs: [Tab] }

struct TabListRenderable: Encodable, CustomStringConvertible {
  let tabs: [Tab]
  private enum Key: String, CodingKey { case tabs }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(tabs.map(TabDTO.init(tab:)), forKey: .tabs)
  }

  var description: String {
    tabs.isEmpty
      ? "(no tabs)"
      : tabs.map { "\($0.id)  \($0.name ?? "(untitled)")  (\($0.panes.count) panes)" }
        .joined(separator: "\n")
  }
}

struct TabDTO: Encodable {
  let id: String
  let name: String?
  let cachedDisplayTitle: String?
  let paneIDs: [String]

  init(tab: Tab) {
    self.id = tab.id.description
    self.name = tab.name
    self.cachedDisplayTitle = tab.cachedDisplayTitle
    self.paneIDs = tab.panes.map { $0.id.description }
  }
}
