import SwiftUI

/// A placeholder row while the first snapshot is on its way: the shape of a
/// worktree row, breathing gently (still under Reduce Motion).
struct SkeletonRow: View {
  /// 0...1, varies the bar widths so a list of them does not look stamped.
  var variant: Double = 0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 20, paused: reduceMotion)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      let breath = reduceMotion ? 1 : 0.75 + 0.25 * (0.5 + 0.5 * sin(t * 2.4 + variant * 3))
      VStack(alignment: .leading, spacing: 9) {
        bar(width: 150 + 70 * variant, height: 13)
        HStack(spacing: Theme.Space.xs) {
          bar(width: 70 + 40 * (1 - variant), height: 9)
          bar(width: 54, height: 9)
        }
      }
      .opacity(breath)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 6)
    .accessibilityHidden(true)
  }

  private func bar(width: CGFloat, height: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
      .fill(Color.surfaceMuted)
      .frame(width: width, height: height)
  }
}
