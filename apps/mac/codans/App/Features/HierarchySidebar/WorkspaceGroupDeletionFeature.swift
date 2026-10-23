import CodansCore
import ComposableArchitecture
import Foundation

/// Reducer for the destructive Workspace delete sheet: one named group
/// (Delete Group…) or every file a Workspace owns (Remove Workspace →
/// Delete Workspace Files…). The sheet shows the deletion check before it
/// lets the user delete: a failed probe blocks until a retry succeeds, and a
/// risk (changes, unpushed commits, running terminals, other files) needs
/// the explicit acknowledgment. `WorkspaceClient` re-runs the same check,
/// so this gate is for the user, not the only guard.
@Reducer
struct WorkspaceGroupDeletionFeature {
  @ObservableState
  struct State: Equatable {
    enum Target: Equatable {
      case group(projectID: ProjectID, groupID: WorkspaceGroupID, name: String)
      case workspace(projectID: ProjectID, name: String)
    }

    enum Phase: Equatable {
      case checking
      case ready
      case deleting
    }

    let target: Target
    var phase: Phase = .checking
    /// One check per named group the delete covers.
    var checks: [GroupDeletionCheck] = []
    /// Tabs of the covered rows that are running something, by display name.
    var runningTerminals: [String] = []
    var deleteBranches: Bool
    var acknowledgesRisks = false
    /// Items the previous attempt could not remove. Transient: after a
    /// restart only the group's `deletion` state is known.
    var previousFailures: [GroupDeletionOutcome.Failure]
    var errorMessage: String?

    init(
      target: Target,
      deleteBranches: Bool = false,
      previousFailures: [GroupDeletionOutcome.Failure] = []
    ) {
      self.target = target
      self.deleteBranches = deleteBranches
      self.previousFailures = previousFailures
    }

    var projectID: ProjectID {
      switch target {
      case .group(let projectID, _, _), .workspace(let projectID, _): projectID
      }
    }

    var isBlocked: Bool { checks.contains(where: \.isBlocked) }
    var hasRisks: Bool { checks.contains(where: \.hasRisks) }
    var deletableBranches: [String] {
      checks.flatMap(\.members).flatMap(\.deletableBranches)
    }

    var canDelete: Bool {
      phase == .ready && !isBlocked && (!hasRisks || acknowledgesRisks)
    }
  }

  enum Action: Equatable {
    /// Runs the check; sent when the sheet opens and by Retry.
    case checkRequested
    case checkLoaded([GroupDeletionCheck])
    case deleteBranchesChanged(Bool)
    case acknowledgesRisksChanged(Bool)
    case deleteTapped
    case deletionFinished(Completion)
    /// The client re-ran the check and refused: the state changed since the
    /// sheet's check, so show the new one and ask again.
    case deletionRejected(GroupDeletionCheck, message: String)
    case deletionFailed(String)
    case cancelTapped
    case delegate(Delegate)

    @CasePathable
    enum Delegate: Equatable {
      case dismissed
      case completed(Completion)
    }
  }

  enum Completion: Equatable {
    case group(projectID: ProjectID, groupID: WorkspaceGroupID, GroupDeletionOutcome)
    case workspace(projectID: ProjectID, WorkspaceRemovalOutcome)
  }

  @Dependency(HierarchyClient.self) private var hierarchyClient
  @Dependency(WorkspaceClient.self) private var workspaceClient

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .checkRequested:
        state.phase = .checking
        state.errorMessage = nil
        let groupIDs: [WorkspaceGroupID]
        switch state.target {
        case .group(_, let groupID, _):
          groupIDs = [groupID]
        case .workspace(let projectID, _):
          groupIDs =
            hierarchyClient.snapshot().projects.first { $0.id == projectID }?
            .workspaceGroups.filter { $0.kind == .named }.map(\.id) ?? []
        }
        return .run { [client = workspaceClient, projectID = state.projectID] send in
          var checks: [GroupDeletionCheck] = []
          for groupID in groupIDs {
            checks.append(await client.checkGroupDeletion(projectID, groupID))
          }
          await send(.checkLoaded(checks))
        }

      case .checkLoaded(let checks):
        state.checks = checks
        state.phase = .ready
        // A new check may list risks the user has not seen yet.
        state.acknowledgesRisks = false
        state.runningTerminals = runningTerminals(for: checks)
        return .none

      case .deleteBranchesChanged(let value):
        state.deleteBranches = value
        return .none

      case .acknowledgesRisksChanged(let value):
        state.acknowledgesRisks = value
        return .none

      case .deleteTapped:
        guard state.canDelete else { return .none }
        state.phase = .deleting
        state.errorMessage = nil
        let request = GroupDeletionRequest(
          deleteBranches: state.deleteBranches, acknowledgeRisks: state.acknowledgesRisks)
        let target = state.target
        return .run { [client = workspaceClient] send in
          do {
            switch target {
            case .group(let projectID, let groupID, _):
              let outcome = try await client.deleteGroup(projectID, groupID, request)
              await send(.deletionFinished(.group(projectID: projectID, groupID: groupID, outcome)))
            case .workspace(let projectID, _):
              let outcome = try await client.removeWorkspace(projectID, .deleteOwnedFiles(request))
              await send(.deletionFinished(.workspace(projectID: projectID, outcome)))
            }
          } catch let error as WorkspaceError {
            switch error {
            case .risksNotAcknowledged(let check), .checkFailed(let check):
              await send(.deletionRejected(check, message: error.localizedDescription))
            default:
              await send(.deletionFailed(error.localizedDescription))
            }
          } catch {
            await send(.deletionFailed(error.localizedDescription))
          }
        }

      case .deletionFinished(let completion):
        return .send(.delegate(.completed(completion)))

      case .deletionRejected(let check, let message):
        if let index = state.checks.firstIndex(where: { $0.groupID == check.groupID }) {
          state.checks[index] = check
        } else {
          state.checks.append(check)
        }
        state.phase = .ready
        state.acknowledgesRisks = false
        state.errorMessage = message
        state.runningTerminals = runningTerminals(for: state.checks)
        return .none

      case .deletionFailed(let message):
        state.phase = .ready
        state.errorMessage = message
        return .none

      case .cancelTapped:
        guard state.phase != .deleting else { return .none }
        return .send(.delegate(.dismissed))

      case .delegate:
        return .none
      }
    }
  }

  /// "<row> › <tab>" for every tab holding a busy pane of the checks.
  private func runningTerminals(for checks: [GroupDeletionCheck]) -> [String] {
    let busy = Set(checks.flatMap(\.busyPaneIDs))
    guard !busy.isEmpty,
      let project = hierarchyClient.snapshot().projects.first(where: { $0.id == checks.first?.projectID })
    else { return [] }
    return project.worktrees.flatMap { row in
      RunningTerminalNames.names(in: row) { tab in tab.panes.contains { busy.contains($0.id) } }
    }
  }
}

/// Display names of the terminals (tabs) of a row that are running
/// something, for confirmations that stop them.
enum RunningTerminalNames {
  static func names(in row: Worktree, isRunning: (Tab) -> Bool) -> [String] {
    row.tabs.enumerated().compactMap { index, tab in
      guard isRunning(tab) else { return nil }
      let title = tab.name ?? tab.cachedDisplayTitle ?? "Tab \(index + 1)"
      return "\(row.name) › \(title)"
    }
  }
}
