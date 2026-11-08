import CodansCore
import ComposableArchitecture
import Foundation

/// Reducer backing the "Open Remote Project" sheet reached from the sidebar's
/// Add Project menu, and its Edit Remote Project form. The user picks a Host from
/// the Host list or enters a new one ("New Host…"), and a remote path. The
/// sheet validates the connection over SSH (reachability → path exists → git
/// detection) and on success emits `delegate(.connected(host:remotePath:gitRoot:))`.
/// Its responsibility ends there — the parent sidebar reducer adds a new Host
/// to the Host list and runs the `addRemoteProject` → reconcile path.
///
/// ADR 0003: a Host from "New Host…" always goes to the Host list; fields
/// equal to an existing Host use that Host. Edit Remote Project changes the Host
/// choice and the path, never the fields of a Host (Settings › Remote Hosts does).
///
/// Authentication is delegated to the user's `~/.ssh/config` + agent; the sheet
/// never collects a password or key.
@Reducer
struct RemoteProjectFeature {
  @ObservableState
  struct State: Equatable {
    /// Add a new Remote Project, or edit an existing one's connection in
    /// place (Host choice / path). Edit re-validates like an add and the
    /// parent applies the result to the existing project.
    enum Mode: Equatable {
      case add
      case edit(projectID: ProjectID)
    }

    /// The entry selected in the Host picker.
    enum HostChoice: Hashable {
      case existing(HostID)
      /// "New Host…": the Host fields show and make a new record.
      case newHost
    }

    var mode: Mode
    /// The Host list, in its order, read when the sheet opens.
    var hosts: [HostRecord]
    var hostChoice: HostChoice
    /// Fields of the "New Host…" entry.
    var newHost: HostDraft
    /// Remote absolute path (or `~/…`). Required.
    var pathDraft: String
    var isConnecting: Bool
    /// Validation / connection failure, rendered in the sheet header.
    var errorMessage: String?

    /// `hostChoice` defaults to the first Host, or "New Host…" when the Host
    /// list is empty.
    init(
      mode: Mode = .add,
      hosts: [HostRecord] = [],
      hostChoice: HostChoice? = nil,
      newHost: HostDraft = HostDraft(),
      pathDraft: String = "",
      isConnecting: Bool = false,
      errorMessage: String? = nil
    ) {
      self.mode = mode
      self.hosts = hosts
      self.hostChoice = hostChoice ?? hosts.first.map { .existing($0.id) } ?? .newHost
      self.newHost = newHost
      self.pathDraft = pathDraft
      self.isConnecting = isConnecting
      self.errorMessage = errorMessage
    }

    var isEditing: Bool {
      if case .edit = mode { return true }
      return false
    }

    var isNewHost: Bool { hostChoice == .newHost }

    /// Whether Connect / Save can run: a path, and a Host or Host field.
    var canConnect: Bool {
      guard !isConnecting, !pathDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return false }
      return !isNewHost || !newHost.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Seed an edit form from an existing Remote Project: its Host and path.
    static func editing(project: Project, hosts: [HostRecord]) -> State? {
      guard let endpoint = project.remoteHost else { return nil }
      var state = State(mode: .edit(projectID: project.id), hosts: hosts, pathDraft: project.rootPath)
      if let hostID = project.hostID, hosts.contains(where: { $0.id == hostID }) {
        state.hostChoice = .existing(hostID)
      } else {
        // No record yet (the next catalog load attaches one): show the
        // Project's fields as a new Host, which reuses a record they equal.
        state.hostChoice = .newHost
        state.newHost = HostDraft(record: HostRecord(endpoint: endpoint))
      }
      return state
    }

    static let hostChangedMessage =
      "The host changed while connecting. Check the host and connect again."

    /// Edit Remote Project error when another Project already has the chosen
    /// Host and path (ADR 0006).
    static func duplicateProjectMessage(name: String, host: HostRecord) -> String {
      "\(name) on \(host.displayName) already uses this path. Choose another path or host."
    }

    /// Show the current Host list after the validated Host changed or was
    /// deleted while the SSH check ran. The result of that check is dropped:
    /// it belongs to the old address. A deleted choice falls back to the
    /// first Host, or "New Host…".
    mutating func hostChangedWhileConnecting(currentHosts: [HostRecord]) {
      hosts = currentHosts
      if case .existing(let id) = hostChoice, !currentHosts.contains(where: { $0.id == id }) {
        hostChoice = currentHosts.first.map { .existing($0.id) } ?? .newHost
      }
      isConnecting = false
      errorMessage = Self.hostChangedMessage
    }

    /// The Host to connect to. "New Host…" fields equal to an existing Host
    /// resolve to that Host.
    func selectedHost() throws(HostRecordError) -> HostRecord {
      switch hostChoice {
      case .existing(let id):
        guard let record = hosts.first(where: { $0.id == id }) else { throw .notFound(id) }
        return record
      case .newHost:
        let record = try newHost.record()
        return hosts.first { $0.identity == record.identity } ?? record
      }
    }
  }

  enum Action: Equatable {
    case hostChoiceChanged(State.HostChoice)
    case addressChanged(String)
    case usernameChanged(String)
    case portChanged(String)
    case nameChanged(String)
    case iconChanged(HostIcon)
    case pathChanged(String)
    case connectButtonTapped
    case connectFailed(String)
    case connectSucceeded(host: HostRecord, remotePath: String, gitRoot: String?)
    case cancelButtonTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismissed
      /// Validated connection. `host` is a record of the Host list, or a new
      /// record the parent adds to it. Parent registers the project via
      /// `addRemoteProject`.
      case connected(host: HostRecord, remotePath: String, gitRoot: String?)
    }
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .hostChoiceChanged(let choice):
        state.hostChoice = choice
        state.errorMessage = nil
        return .none

      case .addressChanged(let value):
        state.newHost.address = value
        return .none

      case .usernameChanged(let value):
        state.newHost.username = value
        return .none

      case .portChanged(let value):
        state.newHost.port = HostDraft.sanitizedPort(value)
        return .none

      case .nameChanged(let value):
        state.newHost.name = value
        return .none

      case .iconChanged(let icon):
        state.newHost.icon = icon
        return .none

      case .pathChanged(let value):
        state.pathDraft = value
        return .none

      case .connectButtonTapped:
        let host: HostRecord
        do {
          host = try state.selectedHost()
        } catch {
          state.errorMessage = error.localizedDescription
          return .none
        }
        let path = state.pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
          state.errorMessage = "Enter the remote path to open."
          return .none
        }
        state.errorMessage = nil
        state.isConnecting = true
        return .run { send in
          await Self.validate(host: host, path: path, send: send)
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
  /// reachability → resolve (one round trip: `~`-expand + exists + `pwd -P`
  /// canonicalize) → git detection. Each failure maps to a user-facing
  /// `connectFailed`; success carries the resolved absolute remote path and
  /// the (optional) remote git root.
  private static func validate(
    host record: HostRecord,
    path: String,
    send: Send<Action>
  ) async {
    let host = record.endpoint
    guard await RemoteReachabilityProbe.isReachable(host: host) else {
      await send(
        .connectFailed("Cannot reach \(host.displayAuthority). Check the host and your SSH config.")
      )
      return
    }
    let service = RemoteGitService(host: host)
    guard let resolved = await service.resolveAbsolutePath(path) else {
      await send(.connectFailed("No directory at \(path) on \(host.displayAuthority)."))
      return
    }
    let gitRoot = await service.discoverGitRoot(candidatePath: resolved)
    await send(.connectSucceeded(host: record, remotePath: resolved, gitRoot: gitRoot))
  }
}
