import Foundation
import CodansCore
import CodansIPC

/// Resolve CLI-side identifiers into canonical UUIDs before issuing the
/// mutation RPC.
///
/// Accepted alias shapes, in priority order:
/// - **UUID** — a literal `UUID().uuidString` is passed through without
///   a round trip. Fast path for scripted agents that already know IDs.
/// - **`current` / `.`** — resolves to the relevant `$CODANS_*_ID`
///   env var (`SPACE_ID`, `PROJECT_ID`, `WORKTREE_ID`, `TAB_ID`, or
///   `PANE_ID` depending on `kind`). Used by commands that default to
///   the current context.
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

    // 2. `current` / `.` pronoun via env vars.
    if value == "current" || value == "." {
      if let envValue = env[envKey(for: kind)], let uuid = UUID(uuidString: envValue) {
        return uuid
      }
      throw Error.noContext(kind: kind)
    }

    // 3. Everything else → server resolver.
    let rpc = try client()
    let contextPaneID: PaneID? = env["CODANS_PANE_ID"].flatMap(UUID.init(uuidString:)).map(PaneID.init(raw:))
    let request = IPC.AliasResolveRequest(
      kind: kind,
      value: value,
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

  public static func envKey(for kind: IPC.AliasResolveRequest.Kind) -> String {
    switch kind {
    case .project: return "CODANS_PROJECT_ID"
    case .worktree: return "CODANS_WORKTREE_ID"
    case .tab: return "CODANS_TAB_ID"
    case .pane: return "CODANS_PANE_ID"
    case .tag: return "CODANS_TAG_ID"
    }
  }
}
