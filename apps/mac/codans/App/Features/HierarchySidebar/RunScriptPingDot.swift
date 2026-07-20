import SwiftUI

/// Trailing "command running" indicator for a worktree row: a solid dot in
/// the running script's tint with a ring that repeatedly expands and fades
/// out of it. Quieter than a spinner — the row's leading slot stays on the
/// worktree icon — but unmistakably alive. Multiple concurrent scripts
/// cycle the dot through their tints; Reduce Motion collapses everything
/// to a static dot.
struct RunScriptPingDot: View {
  let colors: [Color]
  var size: CGFloat = 6
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var uniqueColors: [Color] {
    var seen = Set<Color>()
    return colors.filter { seen.insert($0).inserted }
  }

  var body: some View {
    let resolved = uniqueColors
    Group {
      if resolved.count > 1, !reduceMotion {
        TimelineView(.periodic(from: .now, by: 2.0)) { timeline in
          let index = Self.colorIndex(for: timeline.date, count: resolved.count)
          dot(resolved[index])
            .animation(.easeInOut(duration: 0.6), value: index)
        }
      } else {
        dot(resolved.first ?? .green)
      }
    }
    .accessibilityLabel("Command running")
  }

  private func dot(_ color: Color) -> some View {
    ZStack {
      RunScriptPingRing(color: color, size: size)
      Circle()
        .fill(color)
        .frame(width: size, height: size)
    }
  }

  /// Wall-clock-derived index so the cycle stays stable across re-renders
  /// (no per-view phase state to lose when the row rebuilds).
  private static func colorIndex(for date: Date, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return (Int(date.timeIntervalSinceReferenceDate) / 2) % count
  }
}

/// The expanding ring: scales 1→2 while fading 0.6→0 over one second, then
/// snaps back and repeats. `phaseAnimator` gives the loop for free; the
/// near-zero return leg is what makes the restart read as a fresh ping
/// rather than a reverse collapse. Reduce Motion renders the ring static.
struct RunScriptPingRing: View {
  let color: Color
  let size: CGFloat
  @Environment(\.pixelLength) private var pixelLength
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let ring = Circle()
      .stroke(color, lineWidth: pixelLength)
      .frame(width: size, height: size)
    if reduceMotion {
      ring.opacity(0.6)
    } else {
      ring.phaseAnimator([false, true]) { content, expanded in
        content
          .scaleEffect(expanded ? 2 : 1)
          .opacity(expanded ? 0 : 0.6)
      } animation: { expanded in
        expanded ? .easeOut(duration: 1) : .linear(duration: 0.001)
      }
    }
  }
}
