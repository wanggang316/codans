import SwiftUI

/// Diagonal mask sweep used for skeleton placeholders. Driven by
/// `phaseAnimator` so SwiftUI pauses the timeline when the host view
/// is occluded instead of leaving the animation pipeline spinning
/// forever the way `.repeatForever` would.
struct ShimmerModifier: ViewModifier {
  let isActive: Bool
  @Environment(\.layoutDirection) private var layoutDirection

  private let bandSize: CGFloat = 0.3
  private let gradient = Gradient(colors: [
    .black.opacity(0.6),
    .black,
    .black.opacity(0.6),
  ])

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

  func body(content: Content) -> some View {
    if isActive {
      content.phaseAnimator([false, true]) { content, animating in
        content.mask(
          LinearGradient(
            gradient: gradient,
            startPoint: startPoint(animating: animating),
            endPoint: endPoint(animating: animating)
          )
        )
      } animation: { animating in
        animating ? .linear(duration: 1.5).delay(0.25) : .linear(duration: 0.001)
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
