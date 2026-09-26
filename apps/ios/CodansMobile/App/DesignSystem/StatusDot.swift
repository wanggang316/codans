import SwiftUI

/// A small state dot. With `pulses`, a soft ring breathes out of it: the
/// "working" signal, for agents and for a connection being made.
///
/// The ring is driven by timeline time rather than a repeating animation:
/// a repeating animation's transaction leaks into late layout passes of
/// the toolbar that hosts the dot and animates them too.
struct StatusDot: View {
  let color: Color
  var pulses = false
  var size: CGFloat = 8

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      if pulses, !reduceMotion {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
          let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
          let progress = phase / Self.period
          Circle()
            .fill(color)
            .scaleEffect(1 + 1.4 * progress)
            .opacity(0.45 * (1 - progress))
        }
      }
      Circle().fill(color)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private static let period: Double = 1.6
}
