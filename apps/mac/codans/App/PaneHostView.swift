import AppKit
import CodansCore
import SwiftUI

/// Hosts a `PaneSurface`'s `GhosttySurfaceView` inside SwiftUI.
///
/// The host doesn't own the surface: `TerminalEngine`'s registry does, and the
/// same `GhosttySurfaceView` instance is rendered by every representable that
/// ever shows that pane. Handing that shared view to SwiftUI directly is what
/// made a surviving pane go blank when its sibling closed.
///
/// Closing one leaf of a split collapses the `SplitTree`, so the surviving leaf
/// moves to a different structural position and SwiftUI tears its host down and
/// builds a new one. Both hosts reference the *same* NSView for a moment, so
/// whichever teardown runs last detaches the view the other one is showing —
/// a live terminal with no superview, which renders as an empty pane until
/// something forces a full remount (switching worktrees and back). Worse,
/// `updateNSView` had nothing to re-attach with, so nothing recovered on its
/// own.
///
/// Each host therefore gets its own `PaneSurfaceContainerView` and re-parents
/// the surface into it. Teardown then only ever drops an empty container, and
/// `updateNSView` / `layout()` re-adopt the surface if it ever ends up
/// detached.
struct PaneHostView: NSViewRepresentable {
  /// The pane's live terminal view. Typed as `NSView` rather than
  /// `GhosttySurfaceView` so the re-parenting contract is testable without a
  /// libghostty surface.
  let surfaceView: NSView

  init(surface: PaneSurface) {
    self.surfaceView = surface.view
  }

  init(surfaceView: NSView) {
    self.surfaceView = surfaceView
  }

  func makeNSView(context: Context) -> PaneSurfaceContainerView {
    // Deliberately returns an EMPTY container: the surface is adopted in
    // `updateNSView`, which SwiftUI runs with the container already spliced
    // into the view tree. Adopting here instead would pull the surface out of
    // the outgoing host and into a container that is not in a window yet,
    // which pauses ghostty's renderer for that frame.
    PaneSurfaceContainerView()
  }

  func updateNSView(_ nsView: PaneSurfaceContainerView, context: Context) {
    // Idempotent once this container hosts the view. It carries the surface
    // over from the outgoing host on a rebuild, re-attaches it if a teardown
    // left it detached, and swaps in a replacement surface when a pane is
    // re-created under a live host (retry after a failed bring-up).
    nsView.adopt(surfaceView)
  }

  static func dismantleNSView(_ nsView: PaneSurfaceContainerView, coordinator: ()) {
    // Deliberately does NOT touch the surface view: a newer container may
    // already own it. Surface teardown runs through
    // `HierarchyClient.closePane` → `TerminalEngine.closeSurface`.
    _ = nsView
  }
}

/// Per-host parent for a pane's shared surface view.
///
/// Exists so SwiftUI can create and destroy pane hosts freely while the
/// `GhosttySurfaceView` is created once per Pane and reused — see
/// `PaneHostView` for the failure this prevents. The container carries no
/// behaviour beyond ownership and sizing; it never accepts first responder, so
/// focus, key handling, and drag & drop stay with the surface view.
@MainActor
final class PaneSurfaceContainerView: NSView {
  /// Monotonic creation counter, used by `adopt` so the most recently created
  /// container wins. SwiftUI can still send `updateNSView` to a host it is
  /// about to dismantle; without this ordering rule that late update would
  /// pull the surface back into the dying container.
  private static var nextSequence: UInt64 = 0
  private let sequence: UInt64

  /// The surface view this container claimed. Weak because the surface (and
  /// its view) belong to `TerminalEngine`'s registry.
  private weak var hostedView: NSView?

  init() {
    Self.nextSequence += 1
    self.sequence = Self.nextSequence
    super.init(frame: .zero)
    // Ghostty's surface is layer-backed; a layer-backed parent keeps its Metal
    // layer's ancestry stable across re-parenting.
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) not supported")
  }

  /// Claim `view` for this container. `addSubview` detaches it from its
  /// previous parent, so the hand-off from one host to the next is a single
  /// move rather than a detach/attach pair.
  func adopt(_ view: NSView) {
    guard view.superview !== self else {
      layoutHostedView()
      return
    }
    // A stale host must not reclaim a surface a newer host already owns.
    if let owner = view.superview as? PaneSurfaceContainerView, owner.sequence > sequence {
      return
    }
    hostedView = view
    view.translatesAutoresizingMaskIntoConstraints = true
    view.autoresizingMask = [.width, .height]
    addSubview(view)
    layoutHostedView()
  }

  /// Also the recovery point: if a teardown elsewhere detached the surface we
  /// are showing, the next layout pass pulls it back in. Without this the pane
  /// would stay blank until a remount (tab / worktree switch) rebuilt the host.
  override func layout() {
    super.layout()
    if let hostedView, hostedView.superview !== self {
      adopt(hostedView)
      return
    }
    layoutHostedView()
  }

  private func layoutHostedView() {
    guard let hostedView, hostedView.superview === self, hostedView.frame != bounds else {
      return
    }
    hostedView.frame = bounds
  }
}
