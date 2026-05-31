import Foundation
import TouchCodeCore

protocol HierarchyRuntime: AnyObject {
  /// Allocate the libghostty surface for `pane`, spawning the zmx daemon
  /// that owns the real PTY child first. `async throws` because daemon
  /// spawn (`zmx serve`) and the subsequent control-socket handshake
  /// (`ZmxClient.init` + `attach`) are inherently async.
  func ensureSurface(for pane: Pane, in worktree: Worktree, env: [String: String]) async throws
  func closeSurface(for paneID: PaneID)
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
}

extension HierarchyRuntime {
  func hasSurface(for paneID: PaneID) -> Bool { false }
  func currentWorkingDirectory(for paneID: PaneID) -> String? { nil }
  func focusSurfaceView(for paneID: PaneID) {}
}
