import CodansCore
import SwiftUI

/// Thin progress ring for a `StatusActivity`: a quiet track with an accent arc
/// that fills for determinate progress and sweeps for indeterminate work. When
/// `count` is above one the ring frames it, so the slot says "3 things are
/// running" without growing wider.
struct StatusActivityRing: View {
  let progress: StatusActivity.Progress
  var count: Int = 1
  var diameter: CGFloat = 16
  var lineWidth: CGFloat = 2

  var body: some View {
    ZStack {
      Circle()
        .stroke(.quaternary, lineWidth: lineWidth)
      if let fraction = progress.fraction {
        arc(from: 0, to: fraction, rotation: .zero)
      } else {
        // Drive the sweep from wall-clock time rather than a repeating
        // animation, whose transaction would leak into toolbar layout.
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
          let turns = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
          arc(from: 0, to: 0.28, rotation: .degrees(turns * 360))
        }
      }
      if count > 1 {
        Text(count.formatted())
          .font(.system(size: diameter * 0.6, weight: .semibold).monospacedDigit())
          .minimumScaleFactor(0.5)
          .lineLimit(1)
          .padding(lineWidth)
      }
    }
    .frame(width: diameter, height: diameter)
    .accessibilityHidden(true)
  }

  private func arc(from start: Double, to end: Double, rotation: Angle) -> some View {
    Circle()
      .trim(from: start, to: max(end, 0.02))
      .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
      .rotationEffect(.degrees(-90) + rotation)
  }
}
