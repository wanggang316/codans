import CodansCore
import CodansIPC
import Foundation

/// Resolve CLI-side identifiers into canonical UUIDs before issuing the
/// mutation RPC.
///
/// Accepted alias shapes, in priority order:
/// - **UUID** — a literal `UUID().uuidString` is passed through without
///   a round trip. Fast path for scripted agents that already know IDs.
/// - **`current` / `.`** — resolves to the relevant `$CODANS_*_ID`
///   env var (`SPACE_ID`, `PROJECT_ID`, `WORKTREE_ID`, `TAB_ID`, or
///   `PANE_ID` depending on `kind`). Used by commands that default to
///   the current context. For panes, a missing env var falls through to
///   the server, which attributes the caller to its pane from the
///   connection's kernel peer PID plus a process-ancestry walk.
/// - **`@label`** — pane-only. Routed through `hierarchy.resolveAlias`
///   via the supplied `RPCClient` so the server can match against
///   `Pane.labels`.
/// - **everything else** — sent to `hierarchy.resolveAlias` as a generic
///   string; the server decides whether it's an index, path glob, or
///   unrecognised.
public enum AliasResolver {
  public enum Error: Swift.Error, Equatable, Sendable {
    case noContext(kind: IPC.AliasResolveRequest.Kind)
    case rpc(RPCClient.RPCError)
  }

  /// Resolve `value` to a `UUID`. The `client` is only dialed when the
  /// value is not a UUID and not a context pronoun — callers avoid the
  /// round trip for the common agent-scripting case by passing a
  /// pre-formed UUID string.
  public static func resolve(
    _ value: String,
    kind: IPC.AliasResolveRequest.Kind,
    env: [String: String] = ProcessInfo.processInfo.environment,
    client: @autoclosure () throws -> RPCClient
  ) async throws -> UUID {
    // 1. UUID fast path.
    if let uuid = UUID(uuidString: value) {
      return uuid
    }

    // 2. `current` / `.` pronoun via env vars. A pane only exports its own
    // id, so for every other kind this is a hand-exported override; the
    // server derives project / worktree / tab from the calling pane
    // (kernel peer PID plus an ancestor walk, or `contextPaneID`) when the
    // variable is absent, which also covers a subshell or wrapper that
    // dropped `CODANS_PANE_ID`.
    if value == "current" || value == ".",
      let envValue = env[envKey(for: kind)], let uuid = UUID(uuidString: envValue)
    {
      return uuid
    }

    // 3. Everything else → server resolver. A worktree path is made
    // absolute here (the server has no idea what the CLI's cwd is); only
    // path-shaped values qualify, since branch names contain slashes too.
    let rpc = try client()
    let contextPaneID: PaneID? = env[Self.envKey(for: .pane)].flatMap(UUID.init(uuidString:)).map(PaneID.init(raw:))
    let request = IPC.AliasResolveRequest(
      kind: kind,
      value: kind == .worktree ? Self.absolutePathIfPathShaped(value) : value,
      contextPaneID: contextPaneID
    )
    do {
      let result: IPC.AliasResolveResult = try await rpc.call(
        .hierarchyResolveAlias,
        params: request
      )
      return result.id
    } catch let rpcError as RPCClient.RPCError {
      throw Error.rpc(rpcError)
    }
  }

  /// `/abs`, `~/x`, `./x`, `../x`, and `..` are paths; anything else
  /// (including `bugfix/menu`) is a name. Paths come back absolute and
  /// standardized so the server can compare them to worktree roots.
  static func absolutePathIfPathShaped(
    _ value: String, cwd: String = FileManager.default.currentDirectoryPath
  ) -> String {
    let isPath =
      value.hasPrefix("/") || value.hasPrefix("~/") || value == "~" || value.hasPrefix("./")
      || value.hasPrefix("../") || value == ".."
    guard isPath else { return value }
    let expanded = (value as NSString).expandingTildeInPath
    let url =
      expanded.hasPrefix("/")
      ? URL(fileURLWithPath: expanded)
      : URL(fileURLWithPath: cwd).appendingPathComponent(expanded)
    let path = url.standardizedFileURL.path(percentEncoded: false)
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }

  /// Only `.pane` is ever injected by the app; the others resolve a
  /// `current` pronoun locally only when a caller exported them by hand.
  /// See `CodansEnvironment.Key`.
  public static func envKey(for kind: IPC.AliasResolveRequest.Kind) -> String {
    let key: CodansEnvironment.Key =
      switch kind {
      case .project: .projectID
      case .worktree: .worktreeID
      case .tab: .tabID
      case .pane: .paneID
      case .tag: .tagID
      }
    return key.rawValue
  }
}
