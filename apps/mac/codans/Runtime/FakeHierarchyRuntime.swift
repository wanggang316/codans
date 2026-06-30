import Foundation
import CodansCore

final class FakeHierarchyRuntime: HierarchyRuntime {
  struct SurfaceCall: Equatable {
    let paneID: PaneID
    let worktreeID: WorktreeID
    let env: [String: String]
  }

  private(set) var ensureSurfaceCalls: [SurfaceCall] = []
  private(set) var closeSurfaceCalls: [PaneID] = []
  /// Recorded `suspendSurface` calls — archive's daemon-killing, non-
  /// announcing teardown. Tests assert archive routes through this rather
  /// than `closeSurface`.
  private(set) var suspendSurfaceCalls: [PaneID] = []
  /// Count of `announceHierarchyMutated` calls. Archive fires one after
  /// soft-hiding a worktree so the AgentState reconcile re-runs.
  private(set) var announceHierarchyMutatedCount = 0
  /// Recorded `focusSurfaceView` calls. The manager's tab-switch path
  /// invokes this on the restored last-focused (or leftmost-leaf) pane
  /// id; tests assert the right pane was requested.
  private(set) var focusSurfaceViewCalls: [PaneID] = []
  /// Test-controlled liveness set. Tests assign `livePaneIDs` before
  /// calling the System Under Test; `hasSurface(for:)` returns `true`
  /// iff the pane is present.
  var livePaneIDs: Set<PaneID> = []
  var currentWorkingDirectories: [PaneID: String] = [:]

  // swiftlint:disable async_without_await
  // The `async` keyword is required to conform to `HierarchyRuntime`,
  // whose `ensureSurface` is `async throws` (the live implementation
  // spawns a `zmx serve` daemon and awaits its control-socket
  // handshake). The fake body has no await — keep the marker so lint
  // doesn't trip on a deliberate protocol-conformance shape mismatch.
  func ensureSurface(for pane: Pane, in worktree: Worktree, env: [String: String]) async throws {
    // swiftlint:enable async_without_await
    ensureSurfaceCalls.append(
      SurfaceCall(paneID: pane.id, worktreeID: worktree.id, env: env)
    )
    livePaneIDs.insert(pane.id)
  }

  func closeSurface(for paneID: PaneID) {
    closeSurfaceCalls.append(paneID)
    livePaneIDs.remove(paneID)
  }

  func suspendSurface(for paneID: PaneID) {
    suspendSurfaceCalls.append(paneID)
    livePaneIDs.remove(paneID)
  }

  func announceHierarchyMutated() {
    announceHierarchyMutatedCount += 1
  }

  func hasSurface(for paneID: PaneID) -> Bool {
    livePaneIDs.contains(paneID)
  }

  func currentWorkingDirectory(for paneID: PaneID) -> String? {
    currentWorkingDirectories[paneID]
  }

  func focusSurfaceView(for paneID: PaneID) {
    focusSurfaceViewCalls.append(paneID)
  }

  func reset() {
    ensureSurfaceCalls.removeAll()
    closeSurfaceCalls.removeAll()
    suspendSurfaceCalls.removeAll()
    announceHierarchyMutatedCount = 0
    focusSurfaceViewCalls.removeAll()
    livePaneIDs.removeAll()
    currentWorkingDirectories.removeAll()
  }
}
