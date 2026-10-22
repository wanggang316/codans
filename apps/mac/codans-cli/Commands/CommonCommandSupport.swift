import ArgumentParser
import CodansCore
import CodansIPC
import CodansKit
import Darwin
import Foundation

struct EmptyParams: Codable, Sendable {}

enum CLISession {
  static func connect(globals: GlobalOptions) -> RPCClient {
    let transport: Transport
    do {
      let path = try globals.resolveSocketPath()
      transport = try UnixSocketTransport(path: path)
    } catch {
      CLIError.from(error).exitProcess()
    }
    return RPCClient(
      transport: transport,
      versions: RPCClient.Versions(
        clientVersion: CodansCLI.version,
        clientBinary: CodansCLI.commandName
      ),
      // `--timeout` applies to every call the command makes, alias
      // resolution included, without each call site threading it through.
      defaultTimeout: globals.rpcTimeout
    )
  }
}

struct CLIError: Error, CustomStringConvertible {
  let code: CLIExitCode
  let message: String
  /// Optional next step, rendered as a `  hint: …` line under the error.
  let hint: String?
  /// Stable string code for the JSON envelope; defaults to the exit code's
  /// own (`CLIErrorCode.default(for:)`).
  let errorCode: CLIErrorCode
  /// Structured context for the envelope (`kind` / `id`, `timeoutMs`, …).
  let details: [String: String]
  var description: String { message }

  init(
    code: CLIExitCode,
    message: String,
    hint: String? = nil,
    errorCode: CLIErrorCode? = nil,
    details: [String: String] = [:]
  ) {
    self.code = code
    self.message = message
    self.hint = hint
    self.errorCode = errorCode ?? CLIErrorCode.default(for: code)
    self.details = details
  }

  var payload: CLIErrorPayload {
    CLIErrorPayload(code: errorCode, message: message, hint: hint, details: details)
  }

  static func from(_ error: Error) -> CLIError {
    if let cli = error as? CLIError { return cli }
    if let args = error as? CLIArgumentError {
      if case .missingText = args {
        return CLIError(code: .userError, message: args.description, errorCode: .emptyInput)
      }
      return CLIError(code: .userError, message: args.description)
    }
    if let alias = error as? AliasResolver.Error {
      switch alias {
      case .noContext(let kind):
        return CLIError(
          code: .userError,
          message: "no current \(kind.rawValue) context; pass an explicit id"
        )
      case .rpc(let rpc):
        return from(rpc)
      }
    }
    if let rpc = error as? RPCClient.RPCError {
      return fromRPCError(rpc)
    }
    if let skill = error as? SkillInstaller.Failure {
      switch skill {
      case .unknownSkill(let id):
        return CLIError(code: .notFound, message: skill.description, details: ["kind": "skill", "id": id])
      case .noBundledSkills:
        return CLIError(code: .notFound, message: skill.description)
      case .conflict(let path), .notOurs(let path):
        return CLIError(code: .conflict, message: skill.description, details: ["path": path])
      }
    }
    if let failure = error as? SocketConnectionFailure {
      return CLIError(
        code: CLIExitCode.from(failure),
        message: failure.message,
        hint: failure.hint
      )
    }
    if let refusal = error as? SocketDiscovery.ForeignPaneRefusal {
      return CLIError(code: .wrongChannel, message: refusal.message, hint: refusal.hint)
    }
    return CLIError(code: .internal, message: "\(error)")
  }

  private static func fromRPCError(_ rpc: RPCClient.RPCError) -> CLIError {
    switch rpc {
    case .ipc(.notFound(let kind, let id)) where id == "current" || id == ".":
      // The pronoun could not be attributed to a Tab: the caller is not
      // inside one (or the Tab's shell was replaced). Say what to do.
      return CLIError(
        code: .notFound,
        message: "no current \(kind): this shell is not inside a Codans tab",
        hint: "pass an explicit \(kind) id, or run the command from a tab",
        errorCode: .noCurrentContext,
        details: ["kind": kind]
      )
    case .ipc(.notFound(let kind, let id)):
      return CLIError(
        code: .notFound, message: "\(kind) not found: \(id)", details: ["kind": kind, "id": id])
    case .ipc(.domain(let domainCode, let message, let hint)):
      // The server's code is the envelope's code verbatim so scripts branch
      // on it; one this build does not know is surfaced, not swallowed.
      guard let known = CLIErrorCode(domainCode: domainCode), let exit = known.domainExitCode else {
        return CLIError(code: .internal, message: message, hint: hint, details: ["domainCode": domainCode])
      }
      return CLIError(code: exit, message: message, hint: hint, errorCode: known)
    case .ipc(let ipc):
      return CLIError(code: CLIExitCode.from(ipc), message: ipc.displayMessage)
    case .timeout:
      return CLIError(code: .requestTimeout, message: "request timed out")
    case .noResponse:
      return CLIError(code: .internal, message: "server closed before sending a result")
    case .streamClosed:
      return CLIError(code: .internal, message: "transport stream closed")
    case .decodeFailed(let reason):
      return CLIError(code: .internal, message: "response decode failed: \(reason)")
    case .protocolMismatch(let client, let server):
      return CLIError(
        code: .versionMismatch,
        message: "this CLI speaks IPC protocol \(client), the running app speaks protocol \(server)",
        hint: "use the codans CLI bundled with the running app (same release)",
        details: ["clientProtocol": String(client), "serverProtocol": String(server)]
      )
    case .misorderedResponse(let expected, let got):
      return CLIError(
        code: .internal,
        message: "server sent misordered response (expected id=\(expected), got id=\(got))"
      )
    }
  }

  /// Text mode reports on stderr; JSON mode prints the failure envelope on
  /// stdout so a consumer parses one shape for both outcomes. The exit
  /// code is the same either way.
  func exitProcess(mode: RenderMode = .text(useColor: true)) -> Never {
    switch mode {
    case .json:
      try? Renderer.emitError(payload, mode: .json)
    case .text:
      try? Renderer.emitError(payload, mode: mode) { rendered in
        FileHandle.standardError.write(Data((rendered + "\n").utf8))
      }
    }
    Darwin.exit(code.rawValue)
  }
}

enum StandardInput {
  static func readString() throws -> String {
    guard isatty(STDIN_FILENO) == 0 else {
      throw CLIError(code: .userError, message: "stdin is a terminal; pipe input or pass text arguments")
    }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
      throw CLIError(code: .userError, message: "stdin is not valid UTF-8")
    }
    return text
  }
}

enum PathResolver {
  static func absolute(_ path: String?, defaultingToPWD: Bool = true) -> String {
    let pwd = FileManager.default.currentDirectoryPath
    let raw = (path?.isEmpty == false) ? path! : (defaultingToPWD ? pwd : "")
    if raw.hasPrefix("/") { return raw }
    return URL(fileURLWithPath: pwd).appendingPathComponent(raw).path
  }
}

/// Resolves the container ids a worktree- or tab-scoped verb sends. When the
/// innermost target is named explicitly and its containers are left on
/// `current`, the containers come from the tree rather than the calling
/// session, so `codans tab list --worktree main` works from any shell —
/// the target already determines where it lives.
enum ScopeResolver {
  static func isCurrent(_ value: String) -> Bool { value == "current" || value == "." }

  /// The worktree the Tab and Pane verbs act in. Outside any Tab (a plain
  /// terminal) `current` has nothing to name, so with both containers left
  /// on `current` they fall back to the worktree the window shows.
  static func layoutWorktree(
    project: String, worktree: String, client: RPCClient
  ) async throws -> WorktreePath {
    do {
      return try await Self.worktree(project: project, worktree: worktree, client: client)
    } catch AliasResolver.Error.rpc(.ipc(.notFound(_, let id)))
      where isCurrent(id) && isCurrent(project) && isCurrent(worktree)
    {
      return try await Self.worktree(project: "@selected", worktree: "@selected", client: client)
    }
  }

  static func worktree(
    project: String, worktree: String, client: RPCClient
  ) async throws -> WorktreePath {
    let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
    if isCurrent(project), !isCurrent(worktree) {
      let tree = try await HierarchyTree.load(client: client)
      guard let located = tree.locateWorktree(WorktreeID(raw: worktreeUUID)) else {
        throw CLIError(
          code: .notFound, message: "worktree \(worktreeUUID.uuidString) not found",
          details: ["kind": "worktree", "id": worktreeUUID.uuidString])
      }
      return located
    }
    let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
    return WorktreePath(projectID: ProjectID(raw: projectUUID), worktreeID: WorktreeID(raw: worktreeUUID))
  }

  /// The worktree a Pane-scoped option names: an explicit `--pane` (any of
  /// the three ids) locates its worktree through the tree, so
  /// `tab new --pane p3` works from any shell; otherwise the
  /// `--project` / `--worktree` pair decides.
  static func worktree(
    project: String, worktree: String, pane: String?, client: RPCClient
  ) async throws -> (scope: WorktreePath, paneID: PaneID?) {
    guard let pane else {
      return (try await Self.layoutWorktree(project: project, worktree: worktree, client: client), nil)
    }
    let paneID = PaneID(raw: try await AliasResolver.resolve(pane, kind: .pane, client: client))
    if isCurrent(project), isCurrent(worktree) {
      let tree = try await HierarchyTree.load(client: client)
      guard let located = tree.locatePane(paneID) else {
        throw CLIError(
          code: .notFound, message: "pane \(paneID) not found", details: ["kind": "pane", "id": paneID.description])
      }
      return (WorktreePath(projectID: located.projectID, worktreeID: located.worktreeID), paneID)
    }
    return (try await Self.worktree(project: project, worktree: worktree, client: client), paneID)
  }
}

/// A resolved Tab target: the Tab, its session, and the Pane holding it.
struct TabTarget: Sendable {
  let tabID: TabID
  let contentID: ContentID
  let paneID: PaneID

  /// The ids every session verb's JSON output carries.
  var jsonFields: [String: Any] {
    ["tabID": tabID.description, "contentID": contentID.description, "paneID": paneID.description]
  }

  /// `--tab` / a positional names a Tab by any of the three ids; `--pane`
  /// names a Pane and means its selected Tab. One `hierarchy.describeTab`
  /// fills in the rest (it converts a Pane or Content id to the Tab).
  static func resolve(_ selection: CLITargetSelection, client: RPCClient) async throws -> TabTarget {
    let uuid: UUID
    switch selection {
    case .tab(let value):
      uuid = try await AliasResolver.resolve(value, kind: .tab, client: client)
    case .pane(let value):
      uuid = try await AliasResolver.resolve(value, kind: .pane, client: client)
    }
    let description: IPC.TabDescription = try await client.call(
      .hierarchyDescribeTab, params: IPC.DescribeRequest(id: uuid))
    guard let tabID = UUID(uuidString: description.id), let contentID = UUID(uuidString: description.contentID),
      let paneID = UUID(uuidString: description.paneID)
    else {
      throw CLIError(code: .internal, message: "describeTab returned malformed ids for \(uuid.uuidString)")
    }
    return TabTarget(tabID: TabID(raw: tabID), contentID: ContentID(raw: contentID), paneID: PaneID(raw: paneID))
  }

  /// `--focus`: select the Tab and focus its Pane, as `tab focus` does.
  static func activate(_ target: TabTarget, client: RPCClient) async throws {
    struct Params: Codable { let id: UUID }
    _ = try await client.callRaw(.hierarchyActivateTab, params: Params(id: target.tabID.raw))
  }
}

enum CommandRunner {
  /// Runs a command body with the render context set to the command's
  /// path (`tab.send`), so every JSON envelope it emits — success or the
  /// failure this catches — carries the right `schemaVersion`.
  static func run(
    _ command: some ParsableCommand,
    globals: GlobalOptions,
    _ body: () async throws -> Void
  ) async {
    let context = RenderContext(command: CommandPaths.path(for: type(of: command)))
    await Renderer.$context.withValue(context) {
      do {
        try await body()
      } catch {
        CLIError.from(error).exitProcess(mode: globals.renderMode)
      }
    }
  }
}

/// Dotted command paths (`pane.send`) for every subcommand, walked once
/// from the root configuration; the executable name is left out so the
/// path is the same for `codans` and `codans-dev`.
enum CommandPaths {
  private static let table: [ObjectIdentifier: String] = {
    var table: [ObjectIdentifier: String] = [:]
    func walk(_ type: ParsableCommand.Type, prefix: [String]) {
      for sub in type.configuration.subcommands {
        let path = prefix + [sub.configuration.commandName ?? "unknown"]
        table[ObjectIdentifier(sub)] = path.joined(separator: ".")
        walk(sub, prefix: path)
      }
    }
    walk(CodansCLI.self, prefix: [])
    return table
  }()

  static func path(for type: ParsableCommand.Type) -> String {
    table[ObjectIdentifier(type)] ?? "unknown"
  }
}

struct JSONValueRenderable: Encodable, CustomStringConvertible {
  let value: JSONValue
  init(_ value: JSONValue) { self.value = value }

  func encode(to encoder: Encoder) throws {
    try value.encode(to: encoder)
  }

  var description: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(value)) ?? Data()
    return String(bytes: data, encoding: .utf8) ?? "(unprintable)"
  }
}

struct IDMessage: Encodable, CustomStringConvertible {
  let id: String
  let message: String

  var description: String { message }
}
