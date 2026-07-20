import SwiftUI

/// Hover container for the worktree row's run-script indicator: the ping
/// dot at rest, a red Stop button while the cursor is over it. `onStop`
/// tears down every script executing in the row's worktree — one dot, one
/// button, however many tints are cycling through it. The 12 pt frame both
/// reserves room for the ping ring's 2× expansion and gives the swap a
/// stable hover/hit region, so the cursor can't fall into a gap between
/// "dot leaves" and "button arrives".
struct RunScriptPingStopControl: View {
  let colors: [Color]
  let onStop: () -> Void
  @State private var isHovering = false

  var body: some View {
    ZStack {
      if isHovering {
        Button(action: onStop) {
          // Same red `stop.fill` as the toolbar's Run⇄Stop toggle so the
          // two Stop affordances read as one action.
          Image(systemName: "stop.fill")
            .font(.system(size: 9))
            .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .help("Stop running command")
        .accessibilityLabel("Stop running command")
      } else {
        RunScriptPingDot(colors: colors)
      }
    }
    .frame(width: 12, height: 12)
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }
}

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
