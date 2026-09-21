import Foundation

/// Progress of one workspace creation or member addition, as the app-tier
/// client streams it to whoever asked: the sheet renders it per row, the
/// IPC handler drains it. Members are identified by their folder name,
/// which is unique within a plan.
public nonisolated enum WorkspaceCreationEvent: Equatable, Sendable {
  /// What the client is doing for a member right now.
  public enum Phase: Equatable, Sendable {
    /// `git clone` of a remote source into its local destination.
    case cloning
    /// `git fetch <remote>` so a remote base ref is current.
    case fetching
    /// `git worktree add` of the member checkout.
    case checkingOut
  }

  case memberStarted(name: String, phase: Phase)
  /// One line of subprocess output for the member — clone progress, mostly.
  case progressLine(name: String, line: String)
  case memberFinished(name: String)
  /// The member's step failed; the run is about to roll back and the
  /// stream will finish with the underlying error. Lets a form mark the
  /// row before the error arrives.
  case memberFailed(name: String, message: String)
  case manifestWritten
  /// The workspace (or its new row) is in the catalog. Always the last
  /// event of a successful run. `worktreeID` is the added member's row when
  /// a single member was added to an existing workspace.
  case registered(projectID: ProjectID, worktreeID: WorktreeID?)
  /// Something failed or the caller cancelled; the ledger is being undone.
  case rollingBack
  /// Rollback finished. `failures` names what could not be undone and needs
  /// a hand — empty means the disk is as it was.
  case rolledBack(failures: [String])
}
