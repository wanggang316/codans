import CodansCore
import ComposableArchitecture
import Foundation

/// Reducer backing the "Connect to Server" sheet reached from the sidebar's
/// Add Project menu. Collects the SSH host / port / username / remote path,
/// validates the connection (reachability → path exists → git detection) over
/// SSH, and on success emits `delegate(.connected(host:remotePath:gitRoot:))`.
/// Its responsibility ends there — the parent sidebar reducer runs the
/// `addServerProject` → reconcile path, mirroring how `CloneRepoFeature` hands
/// off a cloned folder.
///
/// Authentication is delegated to the user's `~/.ssh/config` + agent; the sheet
/// never collects a password or key.
@Reducer
struct RemoteConnectionFeature {
  @ObservableState
  struct State: Equatable {
    /// Host or `~/.ssh/config` alias. Required.
    var hostDraft: String = ""
    /// Optional SSH port override. Empty = ssh default (or config alias's port).
    var portDraft: String = ""
    /// Optional username override. Empty = current user (or config alias's user).
    var usernameDraft: String = ""
    /// Remote absolute path (or `~/…`). Required.
    var pathDraft: String = ""
    var isConnecting: Bool = false
    /// Validation / connection failure, rendered in the sheet header.
    var errorMessage: String?
  }

  enum Action: Equatable {
    case hostChanged(String)
    case portChanged(String)
    case usernameChanged(String)
    case pathChanged(String)
    case connectButtonTapped
    case connectFailed(String)
    case connectSucceeded(host: RemoteHost, remotePath: String, gitRoot: String?)
    case cancelButtonTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismissed
      /// Validated connection. Parent registers it via `addServerProject`.
      case connected(host: RemoteHost, remotePath: String, gitRoot: String?)
    }
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .hostChanged(let value):
        state.hostDraft = value
        return .none

      case .portChanged(let value):
        // Keep digits only so the field can't hold a non-numeric port.
        state.portDraft = value.filter(\.isNumber)
        return .none

      case .usernameChanged(let value):
        state.usernameDraft = value
        return .none

      case .pathChanged(let value):
        state.pathDraft = value
        return .none

      case .connectButtonTapped:
        let host = state.hostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = state.pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
          state.errorMessage = "Enter a host or SSH alias."
          return .none
        }
        guard !path.isEmpty else {
          state.errorMessage = "Enter the remote path to open."
          return .none
        }
        let portString = state.portDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var port: Int?
        if !portString.isEmpty {
          guard let parsed = Int(portString), (1...65535).contains(parsed) else {
            state.errorMessage = "Port must be between 1 and 65535."
            return .none
          }
          port = parsed
        }
        let username = state.usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteHost = RemoteHost(
          alias: host,
          username: username.isEmpty ? nil : username,
          port: port
        )
        state.errorMessage = nil
        state.isConnecting = true
        return .run { send in
          await Self.validate(host: remoteHost, path: path, send: send)
        }

      case .connectFailed(let message):
        state.isConnecting = false
        state.errorMessage = message
        return .none

      case .connectSucceeded(let host, let remotePath, let gitRoot):
        state.isConnecting = false
        return .send(.delegate(.connected(host: host, remotePath: remotePath, gitRoot: gitRoot)))

      case .cancelButtonTapped:
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }

  /// Connection validation pipeline, run off the reducer as an effect:
  /// reachability → tilde-expand → directory exists → git detection. Each
  /// failure maps to a user-facing `connectFailed`; success carries the
  /// resolved absolute remote path and the (optional) remote git root.
  private static func validate(
    host: RemoteHost,
    path: String,
    send: Send<Action>
  ) async {
    guard await RemoteReachabilityProbe.isReachable(host: host) else {
      await send(.connectFailed("Cannot reach \(host.displayAuthority). Check the host and your SSH config."))
      return
    }
    let service = RemoteGitService(host: host)
    guard let expanded = await service.expandRemotePath(path) else {
      await send(.connectFailed("Could not resolve \(path) on the host."))
      return
    }
    guard await service.directoryExists(path: expanded) else {
      await send(.connectFailed("No directory at \(expanded) on the host."))
      return
    }
    let gitRoot = await service.discoverGitRoot(candidatePath: expanded)
    await send(.connectSucceeded(host: host, remotePath: expanded, gitRoot: gitRoot))
  }
}
