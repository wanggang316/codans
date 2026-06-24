import AppKit
import SwiftUI
import CodansCore
import UniformTypeIdentifiers

/// Custom drag type for pane moves. Distinct from the tab-chip drag (which
/// rides on `.plainText`) so a pane drag is never accepted by the tab bar and
/// a chip drag is never accepted by the pane grid. In-process only — the
/// payload is the source pane's `PaneID.raw` UUID string.
extension UTType {
  static let touchCodePaneID = UTType(exportedAs: "com.gumpw.codans.pane-id")
}

/// Which edge of a target pane a drag is hovering over. Drives both the drop
/// highlight overlay and the `SplitTree` direction the dropped pane splits
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

  /// The split direction the dropped pane takes relative to the anchor pane.
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

/// Single shared source of truth for the active drop highlight across every
/// pane in a Tab. Holding it here — rather than a per-leaf `@State` — is what
/// keeps the highlight from getting stranded: SwiftUI does not guarantee a
/// `dropExited` when a drag jumps straight from one drop region to another, so
/// a per-leaf flag on the pane the cursor *left* can stay lit. With one shared
/// value only the current target is ever highlighted, and the drop clears it
/// outright.
@MainActor
@Observable
final class PaneDropHighlight {
  /// The pane currently showing the highlight, or nil when idle.
  var target: PaneID?
  /// Which edge of `target` the cursor is over.
  var zone: PaneDropZone?

  /// Armed only between a drag actually starting (from a pane handle) and the
  /// drop. Hover updates are ignored while disarmed — the move re-parents the
  /// dropped pane, which tears down and rebuilds the drop-target views, and
  /// AppKit delivers a stray `dropEntered`/`dropUpdated` to the rebuilt target
  /// *after* `performDrop`. Without this gate that stray callback re-lights the
  /// just-dropped pane and the highlight sticks (confirmed via os_log).
  private var isArmed = false

  // Explicit (nonisolated) deinit: opts out of the synthesized isolated deinit
  // Swift 6 emits for `@MainActor` classes. SplitViewportView releases this
  // object during a `HierarchyManager.catalog` mutation (a tab drag/select
  // tears the split subtree down) inside a SwiftUI transaction flush; an
  // isolated deinit would hop via swift_task_deinitOnExecutorMainActorBackDeploy
  // and double-free a TaskLocal `StopLookupScope` in that cascade (libmalloc
  // abort) — the same footgun fixed for AgentStateOrderCoordinator. Every
  // stored property here is a value type, so the body is empty: the nonisolated
  // tail is the entire point.
  deinit {}

  /// Drag start, from the dragged pane's handle. Arms updates and wipes any
  /// stale highlight so a previous cancelled drag can never linger.
  func begin() {
    isArmed = true
    target = nil
    zone = nil
  }

  /// Hover update from a drop delegate. No-op once disarmed.
  func hover(_ pane: PaneID, _ zone: PaneDropZone) {
    guard isArmed else { return }
    target = pane
    self.zone = zone
  }

  /// `dropExited` from a delegate — retract only if `pane` is the lit one, so a
  /// late exit from a pane the cursor already left can't wipe the current one.
  func exited(_ pane: PaneID) {
    guard target == pane else { return }
    target = nil
    zone = nil
  }

  /// Drop (or end of drag). Disarms and clears outright.
  func end() {
    isArmed = false
    target = nil
    zone = nil
  }
}

/// `DropDelegate` for the pane grid. Mirrors `ChipDropDelegate` (tab reorder):
/// the payload is the source pane's `PaneID.raw` UUID loaded off the provider,
/// and `commit` dispatches a single move on the main actor. The live hover
/// zone is published to the shared `highlight` so exactly one pane lights up.
/// Self-drops are dropped (the anchor never moves relative to itself).
struct PaneDropDelegate: DropDelegate {
  let anchorID: PaneID
  let viewSize: CGSize
  let highlight: PaneDropHighlight
  let commit: @MainActor @Sendable (_ sourceID: PaneID, _ zone: PaneDropZone) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [.touchCodePaneID])
  }

  func dropEntered(info: DropInfo) {
    highlight.hover(anchorID, PaneDropZone.calculate(at: info.location, in: viewSize))
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    highlight.hover(anchorID, PaneDropZone.calculate(at: info.location, in: viewSize))
    return DropProposal(operation: .move)
  }

  func dropExited(info: DropInfo) {
    highlight.exited(anchorID)
  }

  func performDrop(info: DropInfo) -> Bool {
    let zone = PaneDropZone.calculate(at: info.location, in: viewSize)
    highlight.end()
    guard let provider = info.itemProviders(for: [.touchCodePaneID]).first else {
      return false
    }
    let anchorID = self.anchorID
    provider.loadDataRepresentation(
      forTypeIdentifier: UTType.touchCodePaneID.identifier
    ) { [commit] data, _ in
      guard let data,
        let raw = String(data: data, encoding: .utf8),
        let uuid = UUID(uuidString: raw)
      else { return }
      let sourceID = PaneID(raw: uuid)
      guard sourceID != anchorID else { return }
      // `loadDataRepresentation` calls back off the main actor; hop onto
      // MainActor so the non-Sendable TCA store send fires on the correct
      // isolation domain (same dance as ChipDropDelegate).
      Task { @MainActor in
        commit(sourceID, zone)
      }
    }
    return true
  }
}

/// Builds the `NSItemProvider` that carries a pane's identity during a drag.
/// Registered under `.touchCodePaneID` so only the pane grid accepts it.
func paneDragProvider(for paneID: PaneID) -> NSItemProvider {
  let provider = NSItemProvider()
  let data = Data(paneID.raw.uuidString.utf8)
  provider.registerDataRepresentation(
    forTypeIdentifier: UTType.touchCodePaneID.identifier,
    visibility: .all
  ) { completion in
    completion(data, nil)
    return nil
  }
  return provider
}

/// Translucent half-pane highlight showing where the dropped pane will land.
/// Hit-testing disabled so it never interferes with the in-flight drag.
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

/// Full-width grab strip pinned to a pane's top edge — the drag source for a
/// pane move. The terminal surface (`GhosttySurfaceView`, an `NSView`) consumes
/// `mouseDown`, so the drag has to originate from this SwiftUI strip layered
/// above it. It stays fully transparent until hovered so it never clutters the
/// terminal; on hover it reveals a faint fill and an ellipsis glyph and shows
/// the open-hand cursor. Carries the `.onDrag` that emits the pane payload.
struct PaneDragHandle: View {
  let paneID: PaneID
  private let handleHeight: CGFloat = 10
  @State private var isHovering = false
  @Environment(PaneDropHighlight.self) private var highlight

  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(isHovering ? 0.12 : 0))
      .frame(maxWidth: .infinity)
      .frame(height: handleHeight)
      .overlay {
        if isHovering {
          Image(systemName: "ellipsis")
            .font(.system(.callout, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.5))
            .accessibilityHidden(true)
        }
      }
      .contentShape(.rect)
      .onHover { hovering in
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
          NSCursor.openHand.push()
        } else {
          NSCursor.pop()
        }
      }
      .onDisappear {
        if isHovering {
          isHovering = false
          NSCursor.pop()
        }
      }
      .onDrag {
        // Arm the highlight for this drag and clear any stale state before the
        // provider is handed to the system.
        highlight.begin()
        return paneDragProvider(for: paneID)
      }
  }
}
