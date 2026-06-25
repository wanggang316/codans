import ArgumentParser
import Foundation
import CodansCore
import CodansIPC
import CodansKit

struct ProjectList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List projects."
  )

  @OptionGroup var globals: GlobalOptions

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      struct Result: Codable { let projects: [Project] }
      let result: Result = try await client.call(
        .hierarchyListProjects,
        params: EmptyParams()
      )
      try Renderer.emit(ProjectListRenderable(projects: result.projects), mode: globals.renderMode)
    }
  }
}

struct ProjectCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "project",
    abstract: "Create and remove projects.",
    subcommands: [
      ProjectAdd.self,
      ProjectRemove.self,
      ProjectScriptsCommand.self,
    ]
  )
}

/// `codans project commands` — read/manage a Project's saved Commands
/// (`ProjectSettings.scripts`). The user-facing verb is `commands`; the
/// type is named `ProjectScriptsCommand` to avoid colliding with the
/// generic CLI "command" concept. Read-only `list` is the first leaf;
/// add/remove/edit reuse this group.
struct ProjectScriptsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "commands",
    abstract: "Inspect a project's saved commands.",
    subcommands: [
      ProjectCommandsList.self,
    ]
  )
}

struct ProjectCommandsList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List a project's saved commands."
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      struct Params: Codable { let projectID: ProjectID }
      // Honor `--timeout` by threading `globals.rpcTimeout` (D21). Most
      // existing commands hardcode the 10s default; do NOT copy that here —
      // the requestTimeout (exit 11) path depends on this argument.
      let result: ProjectCommandsListPayload = try await client.call(
        .projectListScripts,
        params: Params(projectID: ProjectID(raw: projectUUID)),
        timeout: globals.rpcTimeout
      )
      try Renderer.emit(
        ProjectCommandsListRenderable(scripts: result.scripts),
        mode: globals.renderMode
      )
    }
  }
}

struct ProjectAdd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Add an existing directory as a project."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Project directory.")
  var path: String
  @Option(name: .long, help: "Display name. Defaults to the directory name.")
  var name: String?

  func run() async throws {
    await CommandRunner.run {
      let resolvedPath = PathResolver.absolute(path)
      let displayName = name ?? URL(fileURLWithPath: resolvedPath).lastPathComponent
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      struct Params: Codable {
        let name: String
        let rootPath: String
        let gitRoot: String?
      }
      struct Result: Codable { let id: ProjectID }
      let result: Result = try await client.call(
        .hierarchyAddProject,
        params: Params(name: displayName, rootPath: resolvedPath, gitRoot: nil)
      )
      try Renderer.emitObject(
        ["id": result.id.description, "name": displayName, "path": resolvedPath],
        mode: globals.renderMode
      ) { obj in
        "added project \(obj["id"] ?? "?")  \(displayName)"
      }
    }
  }
}

struct ProjectRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm",
    abstract: "Remove a project from Codans."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Project id, name, or 'current'.")
  var project: String

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(project, kind: .project, client: client)
      struct Params: Codable { let id: ProjectID }
      _ = try await client.callRaw(
        .hierarchyRemoveProject,
        params: Params(id: ProjectID(raw: uuid))
      )
      try Renderer.emit(
        IDMessage(id: uuid.uuidString, message: "removed project \(uuid.uuidString)"), mode: globals.renderMode)
    }
  }
}

struct ProjectListPayload: Codable { let projects: [Project] }

struct ProjectListRenderable: Encodable, CustomStringConvertible {
  let projects: [Project]
  private enum Key: String, CodingKey { case projects }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(projects.map(ProjectDTO.init(project:)), forKey: .projects)
  }

  var description: String {
    projects.isEmpty
      ? "(no projects)"
      : projects.map { "\($0.id)  \($0.name)  \($0.rootPath)" }.joined(separator: "\n")
  }
}

struct ProjectDTO: Encodable {
  let id: String
  let name: String
  let rootPath: String
  let gitRoot: String?
  let selectedWorktreeID: String?

  init(project: Project) {
    self.id = project.id.description
    self.name = project.name
    self.rootPath = project.rootPath
    self.gitRoot = project.gitRoot
    self.selectedWorktreeID = project.selectedWorktreeID?.description
  }
}

/// Wire result for `project.listScripts`. `ScriptDefinition`'s own (omit-when-
/// default) `Codable` decodes the server payload; the CLI re-projects each
/// into a stable-key DTO for `--json` rather than echoing the sparse wire
/// shape.
struct ProjectCommandsListPayload: Codable { let scripts: [ScriptDefinition] }

struct ProjectCommandsListRenderable: Encodable, CustomStringConvertible {
  let scripts: [ScriptDefinition]
  private enum Key: String, CodingKey { case scripts }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(scripts.map(ScriptDefinitionDTO.init(script:)), forKey: .scripts)
  }

  var description: String {
    scripts.isEmpty
      ? "(no commands)"
      // Text shows the resolved label (kind default when unnamed) so an
      // empty-name command still reads as e.g. "Run" / "Lint".
      : scripts.map { "\($0.id)  \($0.displayName)  \($0.command)" }
        .joined(separator: "\n")
  }
}

/// `--json` projection of a `ScriptDefinition`. Distinct from the on-disk
/// `ScriptDefinition` encoding on purpose: this carries a FIXED key set so the
/// `--json` shape is stable across commands and versions. `name` is the raw
/// stored value (`null` when empty — the key is always present), NOT the
/// kind-default fallback; enums travel as their String raw values. Functional
/// run fields (`target` / `direction` / `onFinished` / `focus`) are surfaced
/// for downstream tooling; presentation-only fields (`systemImage`,
/// `tintColor`, `keyboardShortcut`) are intentionally omitted.
struct ScriptDefinitionDTO: Encodable {
  let id: String
  let name: String?
  let command: String
  let kind: String
  let target: String
  let direction: String
  let onFinished: String
  let focus: Bool

  init(script: ScriptDefinition) {
    self.id = script.id.uuidString
    self.name = script.name.isEmpty ? nil : script.name
    self.command = script.command
    self.kind = script.kind.rawValue
    self.target = script.target.rawValue
    self.direction = script.direction.rawValue
    self.onFinished = script.onFinished.rawValue
    self.focus = script.focus
  }

  // Explicit keys + encode so `name == nil` emits `"name": null` rather than
  // dropping the key (default `Encodable` omits nil). VAL-LIST-007/008 require
  // the key set to be identical for every element.
  private enum CodingKeys: String, CodingKey {
    case id, name, command, kind, target, direction, onFinished, focus
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)  // encodes null when nil
    try c.encode(command, forKey: .command)
    try c.encode(kind, forKey: .kind)
    try c.encode(target, forKey: .target)
    try c.encode(direction, forKey: .direction)
    try c.encode(onFinished, forKey: .onFinished)
    try c.encode(focus, forKey: .focus)
  }
}
