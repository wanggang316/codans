import Foundation
import CodansCore

extension IPC {
  /// Params for `pane.close` — the user-explicit termination path. Unlike
  /// `hierarchy.closePane` (which detaches the libghostty surface and
  /// leaves the daemon running so a future attach can resume), this verb
  /// sends `.kill` to the zmx daemon, waits for the daemon's control
  /// socket to disappear (≤ 2 s), reaps the persisted session catalog
  /// entry, and tears down the in-memory hierarchy.
  ///
  /// The locator fields are optional. When omitted, the handler resolves
  /// the pane's catalog location server-side from `paneID` so callers
  /// (typically the CLI) do not need to round-trip through
  /// `hierarchy.resolvePaneLabel` first.
  public struct PaneCloseRequest: Codable, Equatable, Sendable {
    public let paneID: PaneID
    public let tabID: TabID?
    public let worktreeID: WorktreeID?
    public let projectID: ProjectID?

    public init(
      paneID: PaneID,
      tabID: TabID? = nil,
      worktreeID: WorktreeID? = nil,
      projectID: ProjectID? = nil
    ) {
      self.paneID = paneID
      self.tabID = tabID
      self.worktreeID = worktreeID
      self.projectID = projectID
    }
  }

  /// Result for `pane.close`. `closed == false` is the no-op case: the
  /// pane was not present in the catalog (already closed, never opened,
  /// or stale CLI invocation). Callers map that to a non-zero exit so
  /// scripts can tell apart a successful kill from a missing pane.
  public struct PaneCloseResponse: Codable, Equatable, Sendable {
    public let paneID: PaneID
    public let closed: Bool

    public init(paneID: PaneID, closed: Bool) {
      self.paneID = paneID
      self.closed = closed
    }
  }
}
