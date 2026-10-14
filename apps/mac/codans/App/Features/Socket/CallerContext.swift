import CodansIPC
import Darwin
import Foundation

/// Who issued a request. The router checks it before dispatch, so
/// handlers never need to know whether a call came from the local CLI or
/// from a paired phone.
public enum CallerContext: Equatable, Sendable {
  /// A process on this Mac, over the Unix socket. `peerPID` is the
  /// kernel-reported peer (nil on transports without one); only
  /// `hierarchy.resolveAlias` consumes it, for caller-pane attribution.
  case local(peerPID: pid_t?)
  /// A paired device on the LAN gateway, with the permission it holds at
  /// the moment of this request.
  case remote(deviceID: UUID, permission: IPC.RemotePermission)

  /// Peer PID for process-ancestry attribution. Always nil for a remote
  /// caller: a phone has no process on this Mac to attribute.
  public var peerPID: pid_t? {
    switch self {
    case .local(let pid): return pid
    case .remote: return nil
    }
  }

  /// The paired device's permission; nil for a local caller.
  public var remotePermission: IPC.RemotePermission? {
    switch self {
    case .local: return nil
    case .remote(_, let permission): return permission
    }
  }

  /// Nil when the caller may call `method`, otherwise the error to answer
  /// with. Local callers are never gated.
  public func refusal(for method: IPC.Method) -> IPCError? {
    switch self {
    case .local:
      return nil
    case .remote(_, let permission):
      guard !permission.allows(method) else { return nil }
      return .forbidden(reason: "\(method.rawValue) is not available to this device")
    }
  }

  /// `refusal(for:)` on the method, then limits on the parameters a remote
  /// caller may pass to a method its tier allows.
  public func refusal(for request: IPC.Request) -> IPCError? {
    if let refusal = refusal(for: request.method) { return refusal }
    guard case .remote = self else { return nil }
    switch request.method {
    case .hierarchyCreateWorktree:
      // A phone names a branch and the Mac derives the path from its own
      // worktree settings. An explicit path (or adopting an existing one)
      // could register any directory on this Mac as a worktree.
      guard case .object(let fields) = request.params else { return nil }
      let restricted = ["path", "reuseExisting"].filter { key in
        fields[key].map { $0 != .null } ?? false
      }
      guard !restricted.isEmpty else { return nil }
      return .forbidden(
        reason:
          "hierarchy.createWorktree from a paired device takes a branch name, not \(restricted.joined(separator: " or "))"
      )
    default:
      return nil
    }
  }
}
