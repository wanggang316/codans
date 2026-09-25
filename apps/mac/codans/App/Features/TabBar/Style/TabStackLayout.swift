import CoreGraphics
import Foundation

/// Overflow layout of the tab bar — a pure function from (tab count,
/// selection, scroll offset, viewport width) to where every chip is drawn.
///
/// Reproduces AppKit's window-tabbing tab bar (macOS 26), measured by
/// sampling its layout across widths, selections and scroll offsets (max
/// deviation 1 pt). When chips no longer fit at `TabBarMetrics.chipMinWidth`
/// the row scrolls, and instead of being clipped at the viewport edges:
///
/// - Tabs entering a stacking zone at either edge (`zone` wide, active only
///   while there is content to scroll towards on that side) are compressed
///   along a logarithmic curve into thin slivers.
/// - The selected tab never compresses. Once it enters a zone it slows down
///   along a hyperbolic curve; with no tabs left on that side it slides all
///   the way to the edge and stays pinned there. Its neighbours form small
///   local stacks next to it, and farther tabs slide underneath it.
/// - The first / last tab form the bottom of their stack: anchored to the
///   viewport edge, never wider than a chip.
///
/// Coordinates are viewport-relative; `scrollOffset` is the scroll view's
/// content offset. The scroll content itself keeps the 1-pt inter-chip gap
/// (so the scroll range matches the system bar), while the stacked layout
/// uses a gap-less chip stride.
enum TabStackLayout {
  struct Frame: Equatable {
    var x: CGFloat
    var width: CGFloat
    /// Width 0 or entirely outside the viewport — not drawn, not hit-testable.
    var isHidden: Bool
  }

  /// A region a click can land in instead of a tab: clicking a stacked
  /// sliver scrolls the row rather than selecting the tab under it.
  enum StackingRegion: Equatable {
    case leading
    case trailing
    /// Local stack between the selected tab and the tabs before it.
    case beforeSelected
    /// Local stack between the selected tab and the tabs after it.
    case afterSelected
  }

  static let chipWidth: CGFloat = TabBarMetrics.chipMinWidth

  /// Width of each edge stacking zone; the other curve factors scale with it.
  static func zone(viewportWidth: CGFloat) -> CGFloat {
    min(viewportWidth / 8, 128)
  }

  /// Scroll range of a row of `count` chips laid out 1 pt apart.
  static func maxScrollOffset(count: Int, viewportWidth: CGFloat) -> CGFloat {
    max(0, CGFloat(count) * chipWidth + CGFloat(max(count - 1, 0)) * TabBarMetrics.chipSpacing - viewportWidth)
  }

  static func frames(
    count: Int,
    selectedIndex: Int,
    scrollOffset rawOffset: CGFloat,
    viewportWidth width: CGFloat
  ) -> [Frame] {
    guard count > 0 else { return [] }
    let chip = chipWidth
    let maxOffset = maxScrollOffset(count: count, viewportWidth: width)
    // Rubber-band overscroll keeps the edge layout rather than exposing
    // stacks that have nothing to stack.
    let offset = min(max(rawOffset, 0), maxOffset)
    let zone = zone(viewportWidth: width)
    let edgeFactor = zone / 2
    let slowingFactor = zone * 45 / 64
    let compress = { (d: CGFloat) in edgeFactor * log(1 + d / edgeFactor) }
    let slow = { (d: CGFloat) in slowingFactor * d / (d + slowingFactor) }

    let leadingZone: CGFloat = offset > 0 ? zone : 0
    let trailingZone: CGFloat = offset < maxOffset ? zone : 0
    let sel = min(max(selectedIndex, 0), count - 1)

    // 1. The selected tab: linear until one of its edges enters a zone,
    //    then slowed. A zone only applies when tabs remain on that side.
    let linearSelected = CGFloat(sel) * chip - offset
    let pinLeading = sel > 0 ? leadingZone : 0
    let pinTrailing = width - chip - (sel < count - 1 ? trailingZone : 0)
    var selectedX = linearSelected
    if linearSelected < pinLeading {
      selectedX = pinLeading - slow(pinLeading - linearSelected)
    } else if linearSelected > pinTrailing {
      selectedX = pinTrailing + slow(linearSelected - pinTrailing)
    }
    selectedX = min(max(selectedX, 0), width - chip)
    let displacement = selectedX - linearSelected

    var result: [Frame] = []
    result.reserveCapacity(count)
    for index in 0..<count {
      if index == sel {
        result.append(Frame(x: selectedX.rounded(.down), width: chip, isHidden: false))
        continue
      }
      var left = CGFloat(index) * chip - offset
      var right = left + chip
      let leadingBound: CGFloat
      let trailingBound: CGFloat
      if index < sel {
        // Tabs before a selected tab slowed on the leading side ride along
        // with it; ones before a tab slowed on the trailing side stack up
        // against it.
        if displacement > 0 {
          left += displacement
          right += displacement
        }
        leadingBound = leadingZone
        trailingBound = displacement < 0 ? min(width - trailingZone, selectedX - zone) : width - trailingZone
      } else {
        if displacement < 0 {
          left += displacement
          right += displacement
        }
        leadingBound = displacement > 0 ? max(leadingZone, selectedX + chip + zone) : leadingZone
        trailingBound = width - trailingZone
      }
      let map = { (x: CGFloat) -> CGFloat in
        if x < leadingBound { return leadingBound - compress(leadingBound - x) }
        if x > trailingBound { return trailingBound + compress(x - trailingBound) }
        return x
      }
      var start = map(left)
      var end = map(right)
      if index == 0 {
        start = (leadingZone > 0 && left < leadingBound) ? max(0, end - chip) : max(start, 0)
      }
      let anchoredTrailing = index == count - 1 && trailingZone > 0 && right > trailingBound
      if index == count - 1 {
        end = anchoredTrailing ? min(width, start + chip) : min(end, width)
      }
      if index == sel - 1 { end = selectedX }
      if index == sel + 1 { start = selectedX + chip }

      let x: CGFloat
      let frameWidth: CGFloat
      if anchoredTrailing && displacement < 0 {
        x = start.rounded(.down)
        frameWidth = max(0, (end - start).rounded(.down))
      } else {
        x = start.rounded(.down)
        frameWidth = max(0, end.rounded(.down) - x)
      }
      let hidden = frameWidth <= 0 || x >= width || x + frameWidth <= 0
      result.append(Frame(x: x, width: frameWidth, isHidden: hidden))
    }
    return result
  }

  /// Horizontal shift of a compressed chip's content (laid out at full chip
  /// width, then clipped to the sliver), as in the system bar's
  /// `mainContentContainerCenterOffset`. Empirical fit per stack side; the
  /// system value can differ by a few points in thin slivers.
  static func contentOffset(frameWidth: CGFloat, isLeadingSide: Bool, viewportWidth: CGFloat) -> CGFloat {
    guard frameWidth > 0, frameWidth < chipWidth else { return 0 }
    let zone = zone(viewportWidth: viewportWidth)
    let scaled = log(frameWidth / zone)
    let offset = isLeadingSide ? zone * (0.00491 - 0.0605 * scaled) : zone * (-0.04699 - 0.07313 * scaled)
    return max(0, offset.rounded())
  }

  /// Which stacking region, if any, a click at viewport `x` lands in. Only
  /// slivers are regions — a full-width chip is always a normal click target.
  static func stackingRegion(
    atX x: CGFloat,
    frames: [Frame],
    selectedIndex: Int
  ) -> StackingRegion? {
    guard
      let index = frames.indices.last(where: {
        !frames[$0].isHidden && x >= frames[$0].x && x < frames[$0].x + frames[$0].width
      }), index != selectedIndex, frames[index].width < chipWidth
    else { return nil }
    let selectedX = frames.indices.contains(selectedIndex) ? frames[selectedIndex].x : 0
    let selectedIsAtEdge = selectedIndex == 0 || selectedIndex == frames.count - 1
    if index < selectedIndex {
      return (selectedIsAtEdge || x < selectedX - chipWidth) ? .leading : .beforeSelected
    }
    return (selectedIsAtEdge || x > selectedX + 2 * chipWidth) ? .trailing : .afterSelected
  }

  /// Scroll offset the system bar animates to after a click on `region`.
  static func scrollTarget(
    for region: StackingRegion,
    selectedIndex: Int,
    scrollOffset: CGFloat,
    count: Int,
    viewportWidth width: CGFloat
  ) -> CGFloat {
    let zone = zone(viewportWidth: width)
    // One "page": the viewport minus both stacks, half a zone and a chip.
    let page = width - 2.5 * zone - chipWidth
    let selectedLeft = CGFloat(selectedIndex) * chipWidth
    let target: CGFloat
    switch region {
    case .leading: target = scrollOffset - page
    case .trailing: target = scrollOffset + page
    case .beforeSelected: target = min(scrollOffset + page, selectedLeft - (width - chipWidth - zone))
    case .afterSelected: target = max(scrollOffset - page, selectedLeft - zone)
    }
    return min(max(target, 0), maxScrollOffset(count: count, viewportWidth: width))
  }

  /// Offset that brings the tab at `index` into the unstacked area, or nil
  /// when it already is. The system bar does this for a newly added tab;
  /// plain selection changes never scroll.
  static func revealOffset(
    forTabAt index: Int,
    scrollOffset: CGFloat,
    count: Int,
    viewportWidth width: CGFloat
  ) -> CGFloat? {
    let zone = zone(viewportWidth: width)
    let left = CGFloat(index) * chipWidth
    let linear = left - scrollOffset
    let target: CGFloat
    if linear > width - chipWidth - zone {
      target = left - (width - chipWidth - zone)
    } else if linear < zone && scrollOffset > 0 {
      target = left - zone
    } else {
      return nil
    }
    return min(max(target, 0), maxScrollOffset(count: count, viewportWidth: width))
  }
}
