import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

struct WorktreeList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List worktrees for a project."
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
      let result: WorktreeListPayload = try await client.call(
        .hierarchyListWorktrees,
        params: Params(projectID: ProjectID(raw: projectUUID))
      )
      try Renderer.emit(
        WorktreeListRenderable(worktrees: result.worktrees.filter { !$0.archived }),
        mode: globals.renderMode
      )
    }
  }
}

struct WorktreeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "worktree",
    abstract: "List, create, describe, switch, rename, prune, and remove worktrees.",
    subcommands: [
      WorktreeList.self,
      WorktreeNew.self,
      WorktreeShow.self,
      WorktreeSwitch.self,
      WorktreeRename.self,
      WorktreePrune.self,
      WorktreeRemove.self,
    ]
  )
}

struct WorktreeRename: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rename",
    abstract: "Set a worktree's sidebar name (path and branch stay)."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Worktree id, name, branch, or 'current'.")
  var worktree: String
  @Argument(help: "New display name.")
  var name: String
  @Option(name: .long, help: "Project id, name, or 'current'. Usually inferred from the worktree.")
  var project: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let scope = try await ScopeResolver.worktree(project: project, worktree: worktree, client: client)
      struct Params: Codable {
        let id: WorktreeID
        let projectID: ProjectID
        let name: String
      }
      let result: RenameResult = try await client.call(
        .hierarchyRenameWorktree,
        params: Params(id: scope.worktreeID, projectID: scope.projectID, name: name)
      )
      try Renderer.emitObject(
        ["id": result.id, "name": result.name ?? ""],
        mode: globals.renderMode
      ) { _ in "renamed worktree \(result.id) to \(result.name ?? "")" }
    }
  }
}

struct WorktreePrune: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prune",
    abstract: "Run `git worktree prune` for a project and drop the stale rows.",
    discussion: """
      The sidebar's Prune Worktrees: registrations whose directories are gone
      leave git's worktree list, then the project is reconciled so the
      catalog matches. Nothing on disk is deleted.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(project, kind: .project, client: client)
      struct Params: Codable { let projectID: ProjectID }
      struct Result: Decodable { let pruned: Int }
      let result: Result = try await client.call(
        .hierarchyPruneWorktrees,
        params: Params(projectID: ProjectID(raw: uuid))
      )
      try Renderer.emitObject(
        ["projectID": uuid.uuidString, "pruned": result.pruned],
        mode: globals.renderMode
      ) { _ in
        result.pruned == 1 ? "pruned 1 stale worktree" : "pruned \(result.pruned) stale worktrees"
      }
    }
  }
}

struct WorktreeNew: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "new",
    abstract: "Create a git worktree for a branch and add it to the project.",
    discussion: """
      Runs the same pipeline as the New Worktree sheet: the branch is created
      from --base (default: the repo's default remote branch, else HEAD) or
      checked out if it already exists, the project's copy / fetch / setup
      settings apply, and the new worktree becomes the project's selection.
      A --path that already exists on disk is registered as-is.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Branch name.")
  var branch: String
  @Option(name: .long, help: "Committish a new branch starts from (e.g. origin/main).")
  var base: String?
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(
    name: .long,
    help: "Path for the worktree. Defaults to the project's configured worktrees directory."
  )
  var path: String?
  @Option(name: .long, help: "Display name. Defaults to the branch name.")
  var name: String?
  @Flag(
    name: .long,
    help:
      "If a worktree with the same canonical path already exists, return its id instead of failing with a conflict. Name collisions still fail."
  )
  var reuseExisting: Bool = false

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
      let explicitPath = path.map { PathResolver.absolute($0) }
      let displayName = name ?? branch
      struct Params: Codable {
        let projectID: ProjectID
        let name: String
        let path: String?
        let branch: String?
        let reuseExisting: Bool
        let baseRef: String?
      }
      struct Result: Codable {
        let id: WorktreeID
        let path: String
        let created: Bool?
      }
      let result: Result = try await client.call(
        .hierarchyCreateWorktree,
        params: Params(
          projectID: ProjectID(raw: projectUUID),
          name: displayName,
          path: explicitPath,
          branch: branch,
          reuseExisting: reuseExisting,
          baseRef: base
        )
      )
      let created = result.created ?? false
      try Renderer.emitObject(
        [
          "id": result.id.description, "name": displayName, "path": result.path,
          "created": created,
        ],
        mode: globals.renderMode
      ) { _ in
        "\(created ? "created" : "registered") worktree \(result.id.description)  \(displayName)  \(result.path)"
      }
    }
  }
}

struct WorktreeSwitch: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "switch",
    abstract: "Activate a worktree."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Worktree id, name, branch, or 'current'.")
  var worktree: String

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      let uuid = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
      struct Params: Codable { let id: UUID }
      _ = try await client.callRaw(.hierarchyActivateWorktree, params: Params(id: uuid))
      try Renderer.emit(
        IDMessage(id: uuid.uuidString, message: "switched worktree \(uuid.uuidString)"),
        mode: globals.renderMode
      )
    }
  }
}

struct WorktreeRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm",
    abstract: "Remove a worktree entry."
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Worktree id, name, branch, or 'current'. Omit when using --by-path.")
  var worktree: String?
  @Option(name: .long, help: "Project id, name, or 'current'.")
  var project: String = "current"
  @Option(
    name: .long,
    help:
      "Remove every worktree row in the project whose canonical path equals this path. Mutually exclusive with the positional worktree argument."
  )
  var byPath: String?
  @Flag(
    name: .long,
    help:
      "With --by-path, allow removing more than one matching row. Without --all, --by-path requires exactly one match."
  )
  var all: Bool = false
  @Flag(
    name: .long,
    help:
      "Also remove the git worktree from disk (and its branch, per Settings), like the sidebar's Remove Worktree. Without it only the entry is forgotten, and a real git worktree comes back on the next reconcile."
  )
  var delete: Bool = false

  func run() async throws {
    await CommandRunner.run {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }

      if let byPath {
        let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
        // Cleanup mode — list the project's worktrees, filter by
        // canonical path, then issue per-row removes. Done client-side to
        // keep the server's `hierarchy.removeWorktree` surface unchanged.
        guard worktree == nil else {
          throw CLIError(
            code: .userError,
            message: "codans worktree rm: pass either a worktree id OR --by-path, not both"
          )
        }
        let canonical = Self.canonicalize(PathResolver.absolute(byPath))
        struct ListParams: Codable { let projectID: ProjectID }
        let list: WorktreeListPayload = try await client.call(
          .hierarchyListWorktrees,
          params: ListParams(projectID: ProjectID(raw: projectUUID))
        )
        let matches = list.worktrees.filter {
          Self.canonicalize($0.path) == canonical
        }
        if matches.isEmpty {
          throw CLIError(
            code: .notFound,
            message: "no worktree matches path \(canonical) in project \(projectUUID.uuidString)"
          )
        }
        if matches.count > 1 && !all {
          throw CLIError(
            code: .conflict,
            message:
              "path \(canonical) matches \(matches.count) worktrees; re-run with --all to remove every match"
          )
        }
        struct RemoveParams: Codable {
          let id: WorktreeID
          let projectID: ProjectID
          let deleteFromDisk: Bool
        }
        var removed: [String] = []
        for match in matches {
          _ = try await client.callRaw(
            .hierarchyRemoveWorktree,
            params: RemoveParams(
              id: match.id, projectID: ProjectID(raw: projectUUID), deleteFromDisk: delete)
          )
          removed.append(match.id.description)
        }
        try Renderer.emitObject(
          ["removed": removed, "path": canonical, "deleted": delete],
          mode: globals.renderMode
        ) { _ in
          "\(delete ? "deleted" : "removed") \(removed.count) worktree(s) at \(canonical)"
        }
        return
      }

      guard let worktree else {
        throw CLIError(
          code: .userError,
          message: "codans worktree rm: missing worktree id (or pass --by-path <path>)"
        )
      }
      let scope = try await ScopeResolver.worktree(project: project, worktree: worktree, client: client)
      struct Params: Codable {
        let id: WorktreeID
        let projectID: ProjectID
        let deleteFromDisk: Bool
      }
      struct Result: Codable {
        let warning: String?
      }
      let result: Result = try await client.call(
        .hierarchyRemoveWorktree,
        params: Params(id: scope.worktreeID, projectID: scope.projectID, deleteFromDisk: delete)
      )
      try Renderer.emitObject(
        [
          "id": scope.worktreeID.description, "deleted": delete,
          "warning": result.warning.map { JSONValue.string($0) } ?? JSONValue.null,
        ],
        mode: globals.renderMode
      ) { _ in
        var line = "\(delete ? "deleted" : "removed") worktree \(scope.worktreeID)"
        if let warning = result.warning { line += "\n  note: \(warning)" }
        return line
      }
    }
  }

  /// Client-side mirror of `HierarchyManager.canonicalPath` — resolve
  /// symlinks then standardize so `/var/...` and `/private/var/...`
  /// (and similar macOS aliases) collapse to a single comparable form.
  private static func canonicalize(_ path: String) -> String {
    URL(fileURLWithPath: path)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
  }
}

struct WorktreeListPayload: Codable { let worktrees: [Worktree] }

struct WorktreeListRenderable: Encodable, CustomStringConvertible {
  let worktrees: [Worktree]
  private enum Key: String, CodingKey { case worktrees }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(worktrees.map(WorktreeDTO.init(worktree:)), forKey: .worktrees)
  }

  var description: String {
    worktrees.isEmpty
      ? "(no worktrees)"
      : worktrees.map { "\($0.id)  \($0.name)  \($0.branch ?? "(no branch)")  \($0.path)" }
        .joined(separator: "\n")
  }
}

struct WorktreeDTO: Encodable {
  let id: String
  let name: String
  let path: String
  let branch: String?
  let selectedTabID: String?

  init(worktree: Worktree) {
    self.id = worktree.id.description
    self.name = worktree.name
    self.path = worktree.path
    self.branch = worktree.branch
    self.selectedTabID = worktree.selectedTabID?.description
  }
}
