import CodansCore
import SwiftUI

/// One tab-chip drag across the Panes of a Worktree. The chip's own
/// `DragGesture` drives it; every strip and Pane content registers its
/// window frame here, so the session can name the drop target under the
/// cursor:
///
/// - over the source strip: the strip reorders the Tab itself;
/// - over another Pane's strip: the Tab moves into that strip at an index;
/// - over a Pane's content: the Tab moves into a new Pane on the nearest
///   edge — except over its own Pane when it is that Pane's only Tab.
///
/// All frames and the cursor are in the window (`.global`) space, so strips
/// and contents agree whatever view hosts them. One instance per viewport.
@MainActor
@Observable
final class TabDragSession {
  enum Target: Equatable {
    case sourceStrip
    case strip(PaneID, index: Int)
    case edge(PaneID, PaneDropZone)
  }

  struct Drag {
    let tabID: TabID
    let sourcePaneID: PaneID
    /// The Tab is its Pane's only one: an edge drop on that Pane is no move.
    let isLoneTab: Bool
    /// The lifted chip drawn under the cursor away from the source strip.
    let preview: AnyView
  }

  private(set) var drag: Drag?
  /// Cursor in the window space.
  private(set) var location: CGPoint = .zero
  private(set) var target: Target?

  @ObservationIgnored private var stripFrames: [PaneID: CGRect] = [:]
  @ObservationIgnored private var contentFrames: [PaneID: CGRect] = [:]
  @ObservationIgnored private var chipMidXs: [PaneID: [CGFloat]] = [:]
  /// Commits a drop on another Pane. Set by the viewport that owns the store.
  @ObservationIgnored var onDrop: @MainActor (TabID, Target) -> Void = { _, _ in }

  // Explicit (nonisolated) deinit: opts out of the synthesized isolated
  // deinit of a `@MainActor` class. The viewport can release this object
  // inside a catalog mutation's SwiftUI transaction flush, where the
  // isolated deinit hop double-frees a TaskLocal scope (libmalloc abort).
  deinit {}

  func setStripFrame(_ frame: CGRect?, for paneID: PaneID) {
    stripFrames[paneID] = frame
  }

  func setContentFrame(_ frame: CGRect?, for paneID: PaneID) {
    contentFrames[paneID] = frame
  }

  /// Window-space centers of the strip's chips, in strip order.
  func setChipMidXs(_ midXs: [CGFloat]?, for paneID: PaneID) {
    chipMidXs[paneID] = midXs
  }

  func begin(_ drag: Drag, at point: CGPoint) {
    self.drag = drag
    move(to: point)
  }

  func move(to point: CGPoint) {
    guard let drag else { return }
    location = point
    let resolved = Self.resolve(
      point, drag: drag, strips: stripFrames, contents: contentFrames, chipMidXs: chipMidXs)
    if resolved != target { target = resolved }
  }

  /// Ends the drag. A drop on another Pane is committed through `onDrop`;
  /// the return value tells the source strip whether the drop is its own
  /// reorder (`.sourceStrip`) or nothing at all (`nil`).
  @discardableResult
  func end() -> Target? {
    let final = target
    let tabID = drag?.tabID
    drag = nil
    target = nil
    if let final, let tabID, final != .sourceStrip {
      onDrop(tabID, final)
    }
    return final
  }

  /// The drop target under `point`. A strip wins over a content frame; the
  /// strip band reaches a few points past its frame so a chip dragged along
  /// the bar does not flicker out of it.
  static func resolve(
    _ point: CGPoint,
    drag: Drag,
    strips: [PaneID: CGRect],
    contents: [PaneID: CGRect],
    chipMidXs: [PaneID: [CGFloat]]
  ) -> Target? {
    if let (paneID, _) = strips.first(where: { $0.value.insetBy(dx: 0, dy: -stripSlop).contains(point) }) {
      guard paneID != drag.sourcePaneID else { return .sourceStrip }
      let index = (chipMidXs[paneID] ?? []).filter { $0 < point.x }.count
      return .strip(paneID, index: index)
    }
    guard let (paneID, frame) = contents.first(where: { $0.value.contains(point) }) else { return nil }
    if paneID == drag.sourcePaneID, drag.isLoneTab { return nil }
    let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    return .edge(paneID, PaneDropZone.calculate(at: local, in: frame.size))
  }

  private static let stripSlop: CGFloat = 4
}

/// The lifted chip under the cursor while a tab drag is away from its own
/// strip. Converts the session's window-space cursor into this overlay's
/// space; never hit-tested.
struct TabDragPreview: View {
  let session: TabDragSession

  var body: some View {
    GeometryReader { proxy in
      if let drag = session.drag, session.target != .sourceStrip {
        let origin = proxy.frame(in: .global).origin
        drag.preview
          .position(x: session.location.x - origin.x, y: session.location.y - origin.y)
      }
    }
    .allowsHitTesting(false)
  }
}
