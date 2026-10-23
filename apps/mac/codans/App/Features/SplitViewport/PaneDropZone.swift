import SwiftUI
import CodansCore

/// Which edge of a target Pane a dragged tab chip is over. Drives both the
/// drop highlight overlay and the `SplitTree` direction of the Pane the
/// dropped Tab lands in.
enum PaneDropZone: Equatable {
  case top
  case bottom
  case left
  case right

  /// Nearest-edge classification of `point` inside a pane of `size`. Splits
  /// the pane into four triangular quadrants by distance to each edge and
  /// returns the closest: dropping near the left edge puts the Tab in a new
  /// Pane on the left, etc.
  static func calculate(at point: CGPoint, in size: CGSize) -> PaneDropZone {
    guard size.width > 0, size.height > 0 else { return .right }
    let relX = point.x / size.width
    let relY = point.y / size.height
    let candidates: [(PaneDropZone, CGFloat)] = [
      (.left, relX),
      (.right, 1 - relX),
      (.top, relY),
      (.bottom, 1 - relY),
    ]
    return candidates.min(by: { $0.1 < $1.1 })?.0 ?? .right
  }

  /// The split direction the new Pane takes relative to the anchor Pane.
  /// `.up`/`.down` carve a vertical seam; `.left`/`.right` a horizontal one —
  /// see `SplitTree.inserting(_:at:direction:)`.
  var splitDirection: SplitTree<PaneID>.NewDirection {
    switch self {
    case .top: return .up
    case .bottom: return .down
    case .left: return .left
    case .right: return .right
    }
  }
}

/// Translucent half-pane highlight showing where the dropped Tab's new Pane
/// will land. Hit-testing disabled so it never interferes with the drag.
struct PaneDropOverlay: View {
  let zone: PaneDropZone

  var body: some View {
    GeometryReader { geo in
      Rectangle()
        .fill(Color.accentColor.opacity(0.25))
        .frame(width: width(in: geo.size), height: height(in: geo.size))
        .offset(offset(in: geo.size))
    }
    .allowsHitTesting(false)
  }

  private func width(in size: CGSize) -> CGFloat {
    switch zone {
    case .left, .right: return size.width / 2
    case .top, .bottom: return size.width
    }
  }

  private func height(in size: CGSize) -> CGFloat {
    switch zone {
    case .top, .bottom: return size.height / 2
    case .left, .right: return size.height
    }
  }

  private func offset(in size: CGSize) -> CGSize {
    switch zone {
    case .top, .left: return .zero
    case .bottom: return CGSize(width: 0, height: size.height / 2)
    case .right: return CGSize(width: size.width / 2, height: 0)
    }
  }
}
