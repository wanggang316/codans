import AppKit
import SwiftUI
import Testing

@testable import Codans

/// Regression coverage for the shared pane surface staying attached when
/// SwiftUI rebuilds its host.
///
/// A pane surface view is created once per Pane and reused by every
/// representable that renders it. Closing one leaf of a split collapses the
/// `SplitTree`, which moves the surviving leaf to a different structural
/// position, and SwiftUI rebuilds that subtree: a new host is mounted before
/// the old one is dismantled. Without a per-host container the old host's
/// teardown detaches the surface the new host had just adopted, and the
/// surviving pane renders empty (the "stop the run pane, the agent pane goes
/// blank" bug).
@MainActor
struct PaneHostViewReparentTests {
  /// Drives the harness's structural flip the same way the catalog drives
  /// `SplitViewportView` — an observable read inside `body`.
  @Observable
  final class Layout {
    var isSplit: Bool = true
    init() {}
  }

  /// Mirrors `SubtreeView`: the pane is a leaf inside a split container, then
  /// the same leaf rendered at the root once the sibling goes away. The
  /// `if/else` is what makes SwiftUI treat the two as different views.
  private struct Harness: View {
    let surfaceView: NSView
    let layout: Layout

    var body: some View {
      if layout.isSplit {
        HStack(spacing: 0) {
          PaneHostView(surfaceView: surfaceView)
          Color.clear
        }
      } else {
        PaneHostView(surfaceView: surfaceView)
      }
    }
  }

  @Test
  func collapsingTheSplitKeepsTheSurfaceInTheWindow() {
    let surfaceView = NSView()
    let layout = Layout()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }

    let host = NSHostingView(rootView: Harness(surfaceView: surfaceView, layout: layout))
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    window.contentView = host
    window.orderFront(nil)
    settle(host)

    #expect(surfaceView.window === window)

    layout.isSplit = false
    settle(host)

    #expect(surfaceView.window === window)
    #expect(surfaceView.superview is PaneSurfaceContainerView)
  }

  @Test
  func containerSizesTheSurfaceToItsBounds() {
    let surfaceView = NSView()
    let container = PaneSurfaceContainerView()
    container.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
    container.adopt(surfaceView)
    container.layoutSubtreeIfNeeded()

    #expect(surfaceView.frame == container.bounds)
  }

  @Test
  func adoptIsIdempotent() {
    let surfaceView = NSView()
    let container = PaneSurfaceContainerView()
    container.adopt(surfaceView)
    container.adopt(surfaceView)

    #expect(surfaceView.superview === container)
    #expect(container.subviews.count == 1)
  }

  /// A host that is being torn down can still get one last `updateNSView`.
  /// The newest container must keep the surface so that late update cannot
  /// pull it back into a container SwiftUI is about to remove.
  @Test
  func olderContainerCannotReclaimTheSurface() {
    let surfaceView = NSView()
    let older = PaneSurfaceContainerView()
    let newer = PaneSurfaceContainerView()

    older.adopt(surfaceView)
    newer.adopt(surfaceView)
    older.adopt(surfaceView)

    #expect(surfaceView.superview === newer)
  }

  /// The recovery guarantee: a teardown elsewhere can detach the surface (the
  /// blank-pane bug). The live container must pull it back on its next layout
  /// pass rather than wait for a remount.
  @Test
  func detachedSurfaceIsReadoptedOnLayout() {
    let surfaceView = NSView()
    let container = PaneSurfaceContainerView()
    container.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
    container.adopt(surfaceView)

    surfaceView.removeFromSuperview()
    #expect(surfaceView.superview == nil)

    container.layout()

    #expect(surfaceView.superview === container)
    #expect(surfaceView.frame == container.bounds)
  }

  /// Pumps the run loop so SwiftUI applies the pending graph update and the
  /// resulting AppKit view changes land before the assertions run.
  private func settle(_ host: NSView) {
    for _ in 0..<3 {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
    }
  }
}
