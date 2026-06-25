import Foundation
import CodansCore

protocol HierarchyRuntime: AnyObject {
  /// Allocate the libghostty surface for `pane`, spawning the zmx daemon
  /// that owns the real PTY child first. `async throws` because daemon
  /// spawn (`zmx serve`) and the subsequent control-socket handshake
  /// (`ZmxClient.init` + `attach`) are inherently async.
  func ensureSurface(for pane: Pane, in worktree: Worktree, env: [String: String]) async throws
  func closeSurface(for paneID: PaneID)
  /// Archive teardown (soft-hide): kill the pane's zmx daemon and release
  /// any live surface, but do NOT emit a `.paneExited` lifecycle event.
  /// Two ways this differs from `closeSurface`:
  ///  1. The daemon is killed unconditionally. Surfaces are created lazily,
  ///     so a backgrounded archived pane often has no registered surface —
  ///     yet its daemon is still running and would otherwise leak.
  ///  2. No `.paneExited` is emitted. Archive keeps the Pane in the catalog
  ///     for restore, and `.paneExited` would route through
  ///     `RootFeature.paneLifecycleExited → closePane`, deleting it.
  func suspendSurface(for paneID: PaneID)
  /// Reports whether a live terminal surface is currently registered for
  /// the given pane. Used by force-remove to size the
  /// "terminate N running processes" confirmation (spec W-Q3).
  /// Default `false` keeps legacy consumers working without changes.
  func hasSurface(for paneID: PaneID) -> Bool
  /// Returns the live shell-reported working directory for a pane, when
  /// the terminal surface has reported one. Callers fall back to the
  /// catalog's creation-time directory when this is unavailable.
  func currentWorkingDirectory(for paneID: PaneID) -> String?
  /// Makes the pane's surface NSView the window's first responder.
  /// Distinct from `focusPane`/`settingZoomed` (catalog zoom flag) —
  /// this only flips AppKit responder-chain focus so keyboard input
  /// reaches the right surface. No-op if the surface or its window is
  /// not available.
  func focusSurfaceView(for paneID: PaneID)
  /// Broadcast a structural-mutation event (`.hierarchyMutated(.catalog)`)
  /// so catalog-membership reconcilers re-run against the current catalog.
  /// The manager calls this after a structural change that no per-pane
  /// lifecycle event covers — archive's soft-hide is the motivating case:
  /// `suspendSurface` deliberately emits no `.paneExited`, so without this
  /// the `AgentStateStore` reconcile would never fire and the hidden
  /// worktree's agent rows would linger. Default no-op for runtimes that
  /// drive no event stream (e.g. tests that don't assert on it).
  func announceHierarchyMutated()
}

extension HierarchyRuntime {
  func hasSurface(for paneID: PaneID) -> Bool { false }
  func currentWorkingDirectory(for paneID: PaneID) -> String? { nil }
  func focusSurfaceView(for paneID: PaneID) {}
  func announceHierarchyMutated() {}
}
