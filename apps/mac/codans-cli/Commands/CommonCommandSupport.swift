import ArgumentParser
import Darwin
import Foundation
import CodansCore
import CodansIPC
import CodansKit

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
  var description: String { message }

  init(code: CLIExitCode, message: String, hint: String? = nil) {
    self.code = code
    self.message = message
    self.hint = hint
  }

  static func from(_ error: Error) -> CLIError {
    if let cli = error as? CLIError { return cli }
    if let args = error as? CLIArgumentError {
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
      // The pronoun could not be attributed to a pane: the caller is not
      // inside one (or the pane's shell was replaced). Say what to do.
      return CLIError(
        code: .notFound,
        message: "no current \(kind): this shell is not inside a Codans pane",
        hint: "pass an explicit \(kind) id, or run the command from a pane"
      )
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
    case .misorderedResponse(let expected, let got):
      return CLIError(
        code: .internal,
        message: "server sent misordered response (expected id=\(expected), got id=\(got))"
      )
    }
  }

  func exitProcess() -> Never {
    var rendered = "error: \(message)\n"
    if let hint {
      rendered += "  hint: \(hint)\n"
    }
    FileHandle.standardError.write(Data(rendered.utf8))
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
/// `current`, the containers come from the tree rather than the calling pane,
/// so `codans tab close t3` and `codans pane new --tab t3` work from any
/// shell — the target already determines where it lives.
enum ScopeResolver {
  static func isCurrent(_ value: String) -> Bool { value == "current" || value == "." }

  static func worktree(
    project: String, worktree: String, client: RPCClient
  ) async throws -> WorktreePath {
    let worktreeUUID = try await AliasResolver.resolve(worktree, kind: .worktree, client: client)
    if isCurrent(project), !isCurrent(worktree) {
      let tree = try await HierarchyTree.load(client: client)
      guard let located = tree.locateWorktree(WorktreeID(raw: worktreeUUID)) else {
        throw CLIError(code: .notFound, message: "worktree \(worktreeUUID.uuidString) not found")
      }
      return located
    }
    let projectUUID = try await AliasResolver.resolve(project, kind: .project, client: client)
    return WorktreePath(projectID: ProjectID(raw: projectUUID), worktreeID: WorktreeID(raw: worktreeUUID))
  }

  static func tab(
    project: String, worktree: String, tab: String, client: RPCClient
  ) async throws -> TabPath {
    let tabUUID = try await AliasResolver.resolve(tab, kind: .tab, client: client)
    if isCurrent(project), isCurrent(worktree), !isCurrent(tab) {
      let tree = try await HierarchyTree.load(client: client)
      guard let located = tree.locateTab(TabID(raw: tabUUID)) else {
        throw CLIError(code: .notFound, message: "tab \(tabUUID.uuidString) not found")
      }
      return located
    }
    let scope = try await Self.worktree(project: project, worktree: worktree, client: client)
    return TabPath(projectID: scope.projectID, worktreeID: scope.worktreeID, tabID: TabID(raw: tabUUID))
  }
}

enum CommandRunner {
  static func run(_ body: () async throws -> Void) async {
    do {
      try await body()
    } catch {
      CLIError.from(error).exitProcess()
    }
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
