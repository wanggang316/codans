import Foundation
import CodansCore

final class FakeHierarchyRuntime: HierarchyRuntime {
  struct SurfaceCall: Equatable {
    let contentID: ContentID
    let address: TabAddress
    let worktreeID: WorktreeID
    let env: [String: String]
  }

  private(set) var ensureSurfaceCalls: [SurfaceCall] = []
  private(set) var closeSurfaceCalls: [ContentID] = []
  /// Recorded `suspendSurface` calls — archive's daemon-killing, non-
  /// announcing teardown. Tests assert archive routes through this rather
  /// than `closeSurface`.
  private(set) var suspendSurfaceCalls: [ContentID] = []
  /// Count of `announceHierarchyMutated` calls. Archive fires one after
  /// soft-hiding a worktree so the AgentState reconcile re-runs.
  private(set) var announceHierarchyMutatedCount = 0
  /// Recorded `focusSurfaceView` calls. The manager's select / focus paths
  /// invoke this on the selected Tab's Content; tests assert the right
  /// Content was requested.
  private(set) var focusSurfaceViewCalls: [ContentID] = []
  /// Test-controlled liveness set. Tests assign `liveContentIDs` before
  /// calling the System Under Test; `hasSurface(for:)` returns `true`
  /// iff the Content is present.
  var liveContentIDs: Set<ContentID> = []
  var currentWorkingDirectories: [ContentID: String] = [:]

  // swiftlint:disable async_without_await
  // The `async` keyword is required to conform to `HierarchyRuntime`,
  // whose `ensureSurface` is `async throws` (the live implementation
  // awaits the zmx daemon bring-up). The fake body has no await — keep
  // the marker so lint doesn't trip on a deliberate protocol-conformance
  // shape mismatch.
  func ensureSurface(
    for content: ContentSnapshot, at address: TabAddress, in worktree: Worktree, env: [String: String]
  ) async throws {
    // swiftlint:enable async_without_await
    ensureSurfaceCalls.append(
      SurfaceCall(contentID: content.id, address: address, worktreeID: worktree.id, env: env)
    )
    liveContentIDs.insert(content.id)
  }

  func closeSurface(for contentID: ContentID) {
    closeSurfaceCalls.append(contentID)
    liveContentIDs.remove(contentID)
  }

  func suspendSurface(for contentID: ContentID) {
    suspendSurfaceCalls.append(contentID)
    liveContentIDs.remove(contentID)
  }

  func announceHierarchyMutated() {
    announceHierarchyMutatedCount += 1
  }

  func hasSurface(for contentID: ContentID) -> Bool {
    liveContentIDs.contains(contentID)
  }

  func currentWorkingDirectory(for contentID: ContentID) -> String? {
    currentWorkingDirectories[contentID]
  }

  func focusSurfaceView(for contentID: ContentID) {
    focusSurfaceViewCalls.append(contentID)
  }

  func reset() {
    ensureSurfaceCalls.removeAll()
    closeSurfaceCalls.removeAll()
    suspendSurfaceCalls.removeAll()
    announceHierarchyMutatedCount = 0
    focusSurfaceViewCalls.removeAll()
    liveContentIDs.removeAll()
    currentWorkingDirectories.removeAll()
  }
}
