import Foundation
import CodansCore

/// The seam through which `HierarchyManager` drives live Content. Keyed
/// by `ContentID` — the session identity — so a layout change (a Tab
/// moving between Panes) never touches a running surface.
protocol HierarchyRuntime: AnyObject {
  /// Allocate the live surface for `content`, spawning or re-attaching the
  /// zmx daemon that owns the real PTY child. `async throws` because the
  /// live implementation awaits the daemon bring-up.
  func ensureSurface(
    for content: ContentSnapshot, at address: TabAddress, in worktree: Worktree, env: [String: String]
  ) async throws
  /// Kills the daemon and emits `.paneExited`: the Content is gone for good.
  func closeSurface(for contentID: ContentID)
  /// Archive teardown (soft-hide): kill the Content's zmx daemon and release
  /// any live surface, but do NOT emit a `.paneExited` lifecycle event.
  /// Two ways this differs from `closeSurface`:
  ///  1. The daemon is killed unconditionally. Surfaces are created lazily,
  ///     so a backgrounded archived Content often has no registered surface
  ///     — yet its daemon is still running and would otherwise leak.
  ///  2. No `.paneExited` is emitted. Archive keeps the Tab in the catalog
  ///     for restore, and `.paneExited` would route through
  ///     `RootFeature.paneLifecycleExited → closeTab`, deleting it.
  func suspendSurface(for contentID: ContentID)
  /// Whether a live terminal surface is currently registered for the
  /// Content. Used by force-remove to size the "terminate N running
  /// processes" confirmation (spec W-Q3). Default `false`.
  func hasSurface(for contentID: ContentID) -> Bool
  /// The live shell-reported working directory, when the surface has
  /// reported one. Callers fall back to the catalog's directory.
  func currentWorkingDirectory(for contentID: ContentID) -> String?
  /// Makes the Content's surface NSView the window's first responder.
  /// Distinct from `focusPane` (the catalog focus) — this only flips the
  /// AppKit responder chain so keyboard input reaches the right surface.
  /// No-op if the surface or its window is not available.
  func focusSurfaceView(for contentID: ContentID)
  /// Broadcast a structural-mutation event (`.hierarchyMutated(.catalog)`)
  /// so catalog-membership reconcilers re-run against the current catalog.
  /// The manager calls this after a structural change that no per-Content
  /// lifecycle event covers — archive's soft-hide is the motivating case:
  /// `suspendSurface` deliberately emits no `.paneExited`, so without this
  /// the `AgentStateStore` reconcile would never fire and the hidden
  /// worktree's agent rows would linger. Default no-op for runtimes that
  /// drive no event stream (e.g. tests that don't assert on it).
  func announceHierarchyMutated()
}

extension HierarchyRuntime {
  func hasSurface(for contentID: ContentID) -> Bool { false }
  func currentWorkingDirectory(for contentID: ContentID) -> String? { nil }
  func focusSurfaceView(for contentID: ContentID) {}
  func announceHierarchyMutated() {}
}
