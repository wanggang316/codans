import CodansCore
import Foundation

/// One Content kind's live implementation. A `TabContent` exists per
/// registered `ContentID` (see `ContentRuntime`) and owns whatever lives
/// outside the catalog for that session — for a terminal, the libghostty
/// surface and its daemon handle. Adding a content kind is one conformer
/// plus a factory case; the layout layer never learns the kind.
@MainActor
protocol TabContent: AnyObject {
  var id: ContentID { get }
  var kind: ContentKind { get }
  /// Strip-facing state; the chip reads it through the runtime.
  var chrome: TabChrome { get }
  /// Live resources exist right now (terminal: a registered surface).
  /// `false` for a Content whose daemon runs but whose surface was
  /// reclaimed, or that was never brought up this launch.
  var isLive: Bool { get }
  /// The shell-reported working directory, when known.
  var currentWorkingDirectory: String? { get }

  /// Bring the live resources up, or re-attach to the ones that survived
  /// (a zmx daemon outlives its surface). Idempotent. The fresh snapshot,
  /// address and worktree are passed each time because the catalog may
  /// have moved the Tab or changed its directory since the last call.
  func create(
    snapshot: ContentSnapshot, at address: TabAddress, in worktree: Worktree,
    env: [String: String], geometry: ContentGeometry?
  ) async throws
  /// The Content's renderer was placed in a slot of `geometry`.
  func mount(geometry: ContentGeometry)
  /// The renderer left its slot; the Content stays alive.
  func unmount()
  /// Tear down for good: kill the daemon, release the surface. The
  /// runtime drops the instance afterwards.
  func close()
  /// Archive teardown: kill the daemon and release the surface without a
  /// lifecycle event, so the catalog record survives for restore.
  func suspend()
  /// Make the renderer the window's first responder.
  func acceptFocus()
}
