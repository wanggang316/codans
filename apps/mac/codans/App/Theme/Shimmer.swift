import SwiftUI

/// Diagonal mask sweep used for skeleton placeholders.
///
/// The sweep is a pure function of wall-clock time sampled by a
/// `TimelineView` inside the mask, never a SwiftUI animation. An animation
/// driver (`phaseAnimator`, `.repeatForever`) flips its phase in an animated
/// transaction, and any layout change landing in that same update gets
/// interpolated along with it: a skeleton appearing in a window-toolbar item
/// first lays out before the item settles to its fitted size, so its bars
/// grew from a dot at the item's corner over the whole 1.5 s sweep. Driven
/// by time instead, no transaction carries an animation and the masked
/// content always snaps straight to its layout.
struct ShimmerModifier: ViewModifier {
  let isActive: Bool
  @Environment(\.layoutDirection) private var layoutDirection

  private let bandSize: CGFloat = 0.3
  private let gradient = Gradient(colors: [
    .black.opacity(0.6),
    .black,
    .black.opacity(0.6),
  ])

  /// Rest at the start position before each pass, then one linear pass.
  private static let holdDuration: TimeInterval = 0.25
  private static let sweepDuration: TimeInterval = 1.5

  private var minPoint: CGFloat { 0 - bandSize }
  private var maxPoint: CGFloat { 1 + bandSize }

  private func startPoint(animating: Bool) -> UnitPoint {
    if layoutDirection == .rightToLeft {
      return animating ? UnitPoint(x: 0, y: 1) : UnitPoint(x: maxPoint, y: minPoint)
    }
    return animating ? UnitPoint(x: 1, y: 1) : UnitPoint(x: minPoint, y: minPoint)
  }

  private func endPoint(animating: Bool) -> UnitPoint {
    if layoutDirection == .rightToLeft {
      return animating ? UnitPoint(x: minPoint, y: maxPoint) : UnitPoint(x: 1, y: 0)
    }
    return animating ? UnitPoint(x: maxPoint, y: maxPoint) : UnitPoint(x: 0, y: 0)
  }

  /// Sweep position in `0...1` for `date`: 0 through the hold, then linear
  /// to 1 across the pass, then back to 0 for the next cycle.
  private static func sweepProgress(at date: Date) -> CGFloat {
    let elapsed = date.timeIntervalSinceReferenceDate
      .truncatingRemainder(dividingBy: holdDuration + sweepDuration)
    return CGFloat(max(0, elapsed - holdDuration) / sweepDuration)
  }

  private static func interpolate(_ from: UnitPoint, _ to: UnitPoint, _ progress: CGFloat) -> UnitPoint {
    UnitPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
  }

  func body(content: Content) -> some View {
    if isActive {
      content.mask {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
          let progress = Self.sweepProgress(at: context.date)
          LinearGradient(
            gradient: gradient,
            startPoint: Self.interpolate(startPoint(animating: false), startPoint(animating: true), progress),
            endPoint: Self.interpolate(endPoint(animating: false), endPoint(animating: true), progress)
          )
        }
      }
    } else {
      content
    }
  }
}

extension View {
  func shimmer(isActive: Bool) -> some View {
    modifier(ShimmerModifier(isActive: isActive))
  }
}
