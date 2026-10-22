import CodansCore
import CodansIPC
import Foundation

/// Resolve CLI-side identifiers into canonical UUIDs before issuing the
/// mutation RPC.
///
/// Accepted alias shapes, in priority order:
/// - **UUID** — a project / worktree / tag UUID passes through without a
///   round trip. A Pane, Tab or Content UUID always goes to the server,
///   which converts it to the level the verb needs (a Pane names its
///   selected Tab, a Tab or Content names its Pane, and so on).
/// - **`current` / `.`** — resolves to the relevant `$CODANS_*_ID` env
///   var (`PROJECT_ID`, `WORKTREE_ID`, `PANE_ID`, `TAB_ID`, `CONTENT_ID`
///   or `TAG_ID` depending on `kind`). A missing env var falls through to
///   the server, which attributes the caller to its Tab from the
///   connection's kernel peer PID plus a process-ancestry walk.
/// - **`@label`**, **`p<n>` / `t<n>`** and names — sent to
///   `hierarchy.resolveAlias`; the server matches labels, handles, and
///   titles.
public enum AliasResolver {
  public enum Error: Swift.Error, Equatable, Sendable {
    case noContext(kind: IPC.AliasResolveRequest.Kind)
    case rpc(RPCClient.RPCError)
  }

  /// A resolved reference: `id` at the requested level, `matched` the
  /// level the value itself named (`nil` for project / worktree / tag).
  public struct Match: Equatable, Sendable {
    public let id: UUID
    public let matched: IPC.AliasResolveRequest.Kind?

    public init(id: UUID, matched: IPC.AliasResolveRequest.Kind?) {
      self.id = id
      self.matched = matched
    }
  }

  /// Resolve `value` to a `UUID` at `kind`'s level. The `client` is only
  /// dialed when the value cannot be settled locally.
  public static func resolve(
    _ value: String,
    kind: IPC.AliasResolveRequest.Kind,
    env: [String: String] = ProcessInfo.processInfo.environment,
    client: @autoclosure () throws -> RPCClient
  ) async throws -> UUID {
    try await resolveMatch(value, kind: kind, env: env, client: try client()).id
  }

  /// `resolve`, also reporting which level the value named, for a verb
  /// that must refuse a conversion (`pane close` given a Tab).
  public static func resolveMatch(
    _ value: String,
    kind: IPC.AliasResolveRequest.Kind,
    env: [String: String] = ProcessInfo.processInfo.environment,
    client: @autoclosure () throws -> RPCClient
  ) async throws -> Match {
    let isSessionLevel = kind == .pane || kind == .tab || kind == .content

    // 1. UUID fast path for ids that need no conversion.
    if !isSessionLevel, let uuid = UUID(uuidString: value) {
      return Match(id: uuid, matched: nil)
    }

    // 2. `current` / `.` pronoun via env vars. A Tab exports its own Pane,
    // Tab and Content ids, so those are always local; for the other kinds
    // this is a hand-exported override, and the server derives project /
    // worktree from the calling Tab (kernel peer PID plus an ancestor
    // walk, or `contextContentID`) when the variable is absent.
    if value == "current" || value == ".",
      let envValue = env[envKey(for: kind)], let uuid = UUID(uuidString: envValue)
    {
      return Match(id: uuid, matched: isSessionLevel ? kind : nil)
    }

    // 3. Everything else → server resolver. A worktree path is made
    // absolute here (the server has no idea what the CLI's cwd is); only
    // path-shaped values qualify, since branch names contain slashes too.
    let rpc = try client()
    let request = IPC.AliasResolveRequest(
      kind: kind,
      value: kind == .worktree ? Self.absolutePathIfPathShaped(value) : value,
      contextContentID: Self.callerContentID(env: env)
    )
    do {
      let result: IPC.AliasResolveResult = try await rpc.call(
        .hierarchyResolveAlias,
        params: request
      )
      return Match(id: result.id, matched: result.matched)
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

  /// The caller's own session (`CODANS_CONTENT_ID`), sent as the
  /// server-side context for `hierarchy.resolveAlias` and as the caller of
  /// workflow requests. `CODANS_PANE_ID` names a Pane and is never read as
  /// a session id.
  public static func callerContentID(env: [String: String]) -> ContentID? {
    env[CodansEnvironment.Key.contentID.rawValue].flatMap(UUID.init(uuidString:)).map(ContentID.init(raw:))
  }

  /// `.pane`, `.tab` and `.content` are injected by the app; the others
  /// resolve a `current` pronoun locally only when a caller exported them
  /// by hand. See `CodansEnvironment.Key`.
  public static func envKey(for kind: IPC.AliasResolveRequest.Kind) -> String {
    let key: CodansEnvironment.Key =
      switch kind {
      case .project: .projectID
      case .worktree: .worktreeID
      case .tab: .tabID
      case .pane: .paneID
      case .content: .contentID
      case .tag: .tagID
      }
    return key.rawValue
  }
}
