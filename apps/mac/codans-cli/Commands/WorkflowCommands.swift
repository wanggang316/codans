import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Foundation

struct WorkflowCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "workflow",
    abstract: "Run multi-agent workflows: start a run, deliver a step's output, resolve attention.",
    discussion: """
      A workflow is a `<id>.workflow.yaml` file under ~/.codans/workflows/, the
      repository's .codans/workflows/, or the app bundle. `run` binds its roles
      (the calling pane, launched agents, or picked panes), starts the run, and
      returns the frozen bindings. An agent that owns a step with `expect`
      finishes it with `deliver`; `status` without arguments tells an agent
      which run it is in and what is expected of it.

        codans workflow list
        codans workflow run review --role reviewer=auto --input scope=src/
        codans workflow status
        codans workflow deliver --verdict clean - <<'EOF'
        ## Findings
        …
        EOF
        codans workflow resolve <run-id> accept
      """,
    subcommands: [
      WorkflowList.self,
      WorkflowRun.self,
      WorkflowStatus.self,
      WorkflowDeliver.self,
      WorkflowResolve.self,
      WorkflowCancel.self,
      WorkflowRuns.self,
      WorkflowValidate.self,
    ]
  )
}

/// What the app injected into the calling pane's environment. Only the pane
/// id and the activation token are read here; the server treats both as
/// hints and attributes the caller from the connection's peer PID when the
/// pane id is absent (a wrapper or subshell may have dropped it).
enum WorkflowCallerContext {
  static func paneID(in environment: [String: String] = ProcessInfo.processInfo.environment) -> PaneID? {
    environment[CodansEnvironment.Key.paneID.rawValue]
      .flatMap(UUID.init(uuidString:))
      .map(PaneID.init(raw:))
  }

  static func token(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
    environment[CodansEnvironment.Key.workflowToken.rawValue].flatMap { $0.isEmpty ? nil : $0 }
  }
}

/// Parses a full run id. Prefixes are refused: a run id is pasted from a
/// previous `--json` result or `runs` output, and an ambiguous prefix
/// silently matching the wrong run is worse than retyping it.
enum WorkflowRunID {
  static func parse(_ raw: String) throws -> UUID {
    guard let uuid = UUID(uuidString: raw) else {
      throw CLIError(
        code: .userError,
        message: "run id must be a full UUID, got \"\(raw)\"",
        hint: "copy it from `\(CodansCLI.commandName) workflow runs --json`")
    }
    return uuid
  }
}

/// Resolves the optional `source` positional of `run` and the `--worktree`
/// option of `list` / `runs` into what the request carries: a pane id
/// (pane-shaped references) or a worktree id (everything else, tabs
/// included — a tab only determines its worktree).
enum WorkflowSourceResolver {
  struct Resolved: Equatable {
    var paneID: PaneID?
    var worktreeID: WorktreeID?
  }

  static func resolve(_ source: String, client: RPCClient) async throws -> Resolved {
    if let uuid = UUID(uuidString: source) {
      return try await resolveUUID(uuid, client: client)
    }
    if ScopeResolver.isCurrent(source) || source.hasPrefix("@") || isHandle(source, prefix: "p") {
      let uuid = try await AliasResolver.resolve(source, kind: .pane, client: client)
      return Resolved(paneID: PaneID(raw: uuid))
    }
    if isHandle(source, prefix: "t") {
      let uuid = try await AliasResolver.resolve(source, kind: .tab, client: client)
      return Resolved(worktreeID: try await worktree(ofTab: TabID(raw: uuid), client: client))
    }
    let uuid = try await AliasResolver.resolve(source, kind: .worktree, client: client)
    return Resolved(worktreeID: WorktreeID(raw: uuid))
  }

  static func worktree(_ reference: String, client: RPCClient) async throws -> WorktreeID {
    let resolved = try await resolve(reference, client: client)
    if let worktreeID = resolved.worktreeID { return worktreeID }
    guard let paneID = resolved.paneID else { throw notFound("worktree", reference) }
    let tree = try await HierarchyTree.load(client: client)
    guard let located = tree.locatePane(paneID) else { throw notFound("pane", paneID.description) }
    return located.worktreeID
  }

  /// A bare UUID names a pane, a worktree, or a tab; the tree decides.
  private static func resolveUUID(_ uuid: UUID, client: RPCClient) async throws -> Resolved {
    let tree = try await HierarchyTree.load(client: client)
    if tree.locatePane(PaneID(raw: uuid)) != nil {
      return Resolved(paneID: PaneID(raw: uuid))
    }
    if tree.locateWorktree(WorktreeID(raw: uuid)) != nil {
      return Resolved(worktreeID: WorktreeID(raw: uuid))
    }
    if let tab = tree.locateTab(TabID(raw: uuid)) {
      return Resolved(worktreeID: tab.worktreeID)
    }
    throw notFound("source", uuid.uuidString)
  }

  private static func worktree(ofTab tabID: TabID, client: RPCClient) async throws -> WorktreeID {
    let tree = try await HierarchyTree.load(client: client)
    guard let located = tree.locateTab(tabID) else { throw notFound("tab", tabID.description) }
    return located.worktreeID
  }

  private static func isHandle(_ value: String, prefix: Character) -> Bool {
    value.first == prefix && value.count > 1 && value.dropFirst().allSatisfy(\.isNumber)
  }

  private static func notFound(_ kind: String, _ id: String) -> CLIError {
    CLIError(code: .notFound, message: "\(kind) not found: \(id)", details: ["kind": kind, "id": id])
  }
}

struct WorkflowList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List the workflows visible to a worktree with their validity and enabled state.",
    discussion: """
      Inside a pane the list is scoped to that pane's worktree (bundle, user,
      and that repository's definitions); elsewhere every scope is listed.
      Invalid files are listed too, with the diagnostics that explain why.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Option(name: .long, help: "Worktree id, name, branch, path, or a pane/tab reference inside it.")
  var worktree: String?

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      var worktreeID: WorktreeID?
      if let worktree {
        worktreeID = try await WorkflowSourceResolver.worktree(worktree, client: client)
      }
      let response: IPC.WorkflowListResponse = try await client.call(
        .workflowList,
        params: IPC.WorkflowListRequest(
          worktreeID: worktreeID,
          paneID: worktreeID == nil ? WorkflowCallerContext.paneID() : nil)
      )
      try Renderer.emit(WorkflowListRenderable(response: response), mode: globals.renderMode)
    }
  }
}

struct WorkflowRun: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Bind roles, check inputs, and start a workflow run.",
    discussion: """
      The source is the calling pane when the workflow has a `current` role,
      or that pane's worktree otherwise; pass a pane, tab, or worktree
      reference to start elsewhere. --role binds a launch role to a profile
      (name, id, or `auto`) or a pick role to a pane; --input answers a
      declared input; --skip leaves out a step whose delivery nothing else
      needs. When the calling pane is the `current` role and the first step
      messages it, the response carries the task itself instead of typing it
      back into the pane.

        codans workflow run review
        codans workflow run review p3 --role reviewer="Claude Code"
        codans workflow run release --input version=1.2.0 --skip changelog
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Workflow id, or its display name when unique.")
  var workflow: String
  @Argument(help: "Source pane (p<n>, @label, 'current'), tab (t<n>), or worktree; default: the calling pane.")
  var source: String?
  @Option(name: .long, help: "Role binding as name=value (profile name/id, 'auto', or a pane for pick roles).")
  var role: [String] = []
  @Option(name: .long, help: "Workflow input as name=value.")
  var input: [String] = []
  @Option(name: .long, help: "Step id to skip.")
  var skip: [String] = []

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let roles = try CLIKeyValuePairs.parse(role, option: "--role")
      let inputs = try CLIKeyValuePairs.parse(input, option: "--input")
      let client = CLISession.connect(globals: globals)
      defer { Task { await client.shutdown() } }
      var resolved = WorkflowSourceResolver.Resolved(paneID: WorkflowCallerContext.paneID())
      if let source {
        resolved = try await WorkflowSourceResolver.resolve(source, client: client)
      }
      let response: IPC.WorkflowRunResponse = try await client.call(
        .workflowRun,
        params: IPC.WorkflowRunRequest(
          workflow: workflow,
          sourcePaneID: resolved.paneID,
          worktreeID: resolved.worktreeID,
          callerPaneID: WorkflowCallerContext.paneID(),
          roles: roles,
          inputs: inputs,
          skip: skip,
          origin: "cli"
        )
      )
      try Renderer.emit(WorkflowRunRenderable(response: response), mode: globals.renderMode)
    }
  }
}

struct WorkflowValidate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "validate",
    abstract: "Check a workflow file offline, without the app.",
    discussion: """
      Parses and validates one `<id>.workflow.yaml` file and prints its
      diagnostics. Exits 0 when the file has no errors.
      """
  )

  @OptionGroup var globals: GlobalOptions
  @Argument(help: "Path to a .workflow.yaml file.")
  var file: String

  func run() async throws {
    await CommandRunner.run(self, globals: globals) {
      let path = PathResolver.absolute(file)
      let url = URL(fileURLWithPath: path, isDirectory: false)
      guard let id = WorkflowDocumentParser.workflowID(fromFileName: url.lastPathComponent) else {
        throw CLIError(
          code: .userError,
          message: "\(url.lastPathComponent) is not a workflow file: expected <id>\(WorkflowDocumentParser.fileSuffix)",
          details: ["file": path])
      }
      guard let entry = WorkflowDiscovery.load(url: url, id: id, scope: .user) else {
        throw CLIError(code: .notFound, message: "cannot read \(path)", details: ["file": path])
      }
      try Renderer.emit(WorkflowValidateRenderable(entry: entry), mode: globals.renderMode)
      if !entry.isValid {
        throw CLIError(
          code: .userError,
          message: "\(entry.diagnostics.filter(\.isError).count) error(s) in \(url.lastPathComponent)",
          errorCode: .workflowInvalid,
          details: ["file": path])
      }
    }
  }
}
