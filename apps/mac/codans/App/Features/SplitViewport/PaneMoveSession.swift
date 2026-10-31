import CodansCore
import SwiftUI

/// Which edge of a target pane a move is hovering over. Drives both the drop
/// highlight overlay and the `SplitTree` direction the moved pane splits
/// along.
enum PaneDropZone: Equatable {
  case top
  case bottom
  case left
  case right

  /// Nearest-edge classification of `point` inside a pane of `size`. Splits
  /// the pane into four triangular quadrants by distance to each edge and
  /// returns the closest. Mirrors the divider semantics: dropping near the
  /// left edge re-homes the pane to the left, etc.
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

  /// The split direction the moved pane takes relative to the anchor pane.
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

/// State of one pane move inside a viewport: which pane is moving, and
/// which edge of which pane it would land on.
///
/// The move is an in-window drag gesture on the pane header, not a system
/// drag session. A system drag floats a drag image in its own window, which
/// lags the pointer and has no meaning outside this viewport. The gesture
/// reports locations in `coordinateSpace`, and every card reports its frame
/// in the same space, so the target is a plain hit test.
@MainActor
@Observable
final class PaneMoveSession {
  static let coordinateSpace = "PaneMoveSession.viewport"

  /// The pane being moved, or nil when no move is in progress.
  private(set) var source: PaneID?
  /// Title of the moving pane, for the chip that follows the pointer.
  private(set) var sourceTitle = ""
  /// Pointer location in `coordinateSpace` while a move is in progress.
  private(set) var location: CGPoint = .zero
  /// The pane under the pointer, other than the source.
  private(set) var target: PaneID?
  /// Which edge of `target` the pointer is over.
  private(set) var zone: PaneDropZone?
  /// Card frames in `coordinateSpace`, from `PaneFramesPreferenceKey`.
  @ObservationIgnored var frames: [PaneID: CGRect] = [:]

  // Explicit (nonisolated) deinit: opts out of the synthesized isolated deinit
  // Swift 6 emits for `@MainActor` classes. SplitViewportView releases this
  // object during a `HierarchyManager.catalog` mutation (a tab drag/select
  // tears the split subtree down) inside a SwiftUI transaction flush; an
  // isolated deinit would hop via swift_task_deinitOnExecutorMainActorBackDeploy
  // and double-free a TaskLocal `StopLookupScope` in that cascade (libmalloc
  // abort). Every stored property here is a value type, so the body is empty:
  // the nonisolated tail is the entire point.
  deinit {}

  /// Pointer moved to `location` while `pane` is dragged. Starts the move on
  /// the first call.
  func drag(_ pane: PaneID, title: String = "", to location: CGPoint) {
    if source != pane {
      source = pane
      sourceTitle = title
    }
    self.location = location
    guard
      let (hit, frame) = frames.first(where: { $0.key != pane && $0.value.contains(location) })
    else {
      if target != nil { target = nil }
      if zone != nil { zone = nil }
      return
    }
    let local = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
    let newZone = PaneDropZone.calculate(at: local, in: frame.size)
    if target != hit { target = hit }
    if zone != newZone { zone = newZone }
  }

  /// Ends the move. Returns where the source pane lands, or nil when the
  /// pointer is not over another pane.
  func finish() -> (source: PaneID, anchor: PaneID, zone: PaneDropZone)? {
    defer { cancel() }
    guard let source, let target, let zone else { return nil }
    return (source, target, zone)
  }

  /// Ends the move without a drop.
  func cancel() {
    source = nil
    sourceTitle = ""
    target = nil
    zone = nil
  }
}

/// The moving pane's title chip, drawn at the pointer so the user sees
/// what is being moved. It is part of the viewport, not a drag image, so it
/// tracks the pointer exactly and never leaves the window.
struct PaneMoveChip: View {
  let session: PaneMoveSession

  var body: some View {
    if session.source != nil {
      HStack(spacing: PaneCardMetrics.titleChipSpacing) {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
          .font(.system(size: PaneCardMetrics.moveGlyphSize, weight: .medium))
          .frame(width: PaneCardMetrics.headerIconSize, height: PaneCardMetrics.headerIconSize)
          .accessibilityHidden(true)
        Text(session.sourceTitle)
          .font(.system(size: PaneCardMetrics.headerTitleFontSize))
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .foregroundStyle(.primary)
      .padding(.leading, PaneCardMetrics.titleChipLeadingInset)
      .padding(.trailing, PaneCardMetrics.titleChipTrailingInset)
      .frame(height: PaneCardMetrics.titleChipHeight)
      .frame(maxWidth: PaneCardMetrics.moveChipMaxWidth)
      .fixedSize()
      .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
      .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
      // The pointer holds the chip by its move mark, as it held the header.
      .alignmentGuide(.leading) { _ in
        PaneCardMetrics.titleChipLeadingInset + PaneCardMetrics.headerIconSize / 2
      }
      .alignmentGuide(.top) { $0.height / 2 }
      .offset(x: session.location.x, y: session.location.y)
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }
}

/// Card frames in `PaneMoveSession.coordinateSpace`, keyed by pane.
struct PaneFramesPreferenceKey: PreferenceKey {
  static let defaultValue: [PaneID: CGRect] = [:]

  static func reduce(value: inout [PaneID: CGRect], nextValue: () -> [PaneID: CGRect]) {
    value.merge(nextValue()) { $1 }
  }
}

/// Half-card highlight showing where the moved pane will land. Hit-testing
/// disabled so it never interferes with the move gesture.
struct PaneDropOverlay: View {
  let zone: PaneDropZone

  var body: some View {
    GeometryReader { geo in
      let rect = rect(in: geo.size).insetBy(dx: Self.inset, dy: Self.inset)
      let shape = RoundedRectangle(
        cornerRadius: PaneCardMetrics.cornerRadius - Self.inset, style: .continuous)
      shape
        .fill(Color.accentColor.opacity(0.14))
        .overlay(shape.strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5))
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .animation(.easeOut(duration: 0.12), value: zone)
    }
    .allowsHitTesting(false)
  }

  private static let inset: CGFloat = 4

  private func rect(in size: CGSize) -> CGRect {
    switch zone {
    case .left: return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
    case .right: return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
    case .top: return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
    case .bottom:
      return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
    }
  }
}
