import GhosttyKit
import SwiftUI
import TouchCodeCore

/// Thin (2pt) progress bar overlaid on a live terminal surface. Reads
/// `SurfaceInfo.progressState` / `progressValue` — both populated from
/// libghostty's OSC 9;4 progress reports (`ghostty_action_progress_report_*`)
/// — and renders one of three animations:
///
/// - Indeterminate (no value): a translucent track with a 25% sliver
///   panning back and forth.
/// - Determinate (value 0…100): a solid bar that grows to the reported
///   percentage with a short ease.
/// - Paused (`PAUSE`): full bar pinned at the orange / amber accent so
///   the suspended-but-not-cleared state is distinguishable from done.
///
/// Gives programs emitting OSC 9;4 (winget, some `gh` / `cargo`
/// subcommands, the Claude Code CLI while it executes tool calls, etc.)
/// a place to surface "I'm doing something" without drawing extra
/// terminal chrome. Plain interactive commands (make, npm, go build,
/// git, pytest) don't emit OSC 9;4 themselves — coverage of those is
/// the job of a separate shell-integration layer that wraps
/// preexec/precmd around each prompt.
struct PaneSurfaceProgressBar: View {
  let progressState: UInt32
  let progressValue: Int?

  var body: some View {
    let color: Color = colorForState()
    // libghostty signals "paused at completion" with a state-only
    // event; pin the bar at 100% so the remaining sliver doesn't
    // mislead the user into thinking the operation is mid-flight.
    let progress: Int? =
      progressValue ?? (progressState == GHOSTTY_PROGRESS_STATE_PAUSE.rawValue ? 100 : nil)
    let label = accessibilityLabel()
    let value = accessibilityValue(progress: progress)

    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        if let progress {
          Rectangle()
            .fill(color)
            .frame(
              width: geometry.size.width * CGFloat(progress) / 100,
              height: geometry.size.height
            )
            .animation(.easeInOut(duration: 0.2), value: progress)
        } else {
          ZStack(alignment: .leading) {
            Rectangle()
              .fill(color.opacity(0.3))
            Rectangle()
              .fill(color)
              .frame(width: geometry.size.width * 0.25, height: geometry.size.height)
              .phaseAnimator([false, true]) { content, moved in
                content.offset(x: moved ? geometry.size.width * 0.75 : 0)
              } animation: { _ in
                .easeInOut(duration: 1.2)
              }
          }
        }
      }
    }
    .frame(height: 2)
    .clipped()
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.updatesFrequently)
    .accessibilityLabel(label)
    .accessibilityValue(value)
  }

  private func colorForState() -> Color {
    switch progressState {
    case GHOSTTY_PROGRESS_STATE_ERROR.rawValue: return .red
    case GHOSTTY_PROGRESS_STATE_PAUSE.rawValue: return .orange
    default: return .accentColor
    }
  }

  private func accessibilityLabel() -> String {
    switch progressState {
    case GHOSTTY_PROGRESS_STATE_ERROR.rawValue: return "Terminal progress - Error"
    case GHOSTTY_PROGRESS_STATE_PAUSE.rawValue: return "Terminal progress - Paused"
    case GHOSTTY_PROGRESS_STATE_INDETERMINATE.rawValue: return "Terminal progress - In progress"
    default: return "Terminal progress"
    }
  }

  private func accessibilityValue(progress: Int?) -> String {
    if let progress { return "\(progress) percent complete" }
    switch progressState {
    case GHOSTTY_PROGRESS_STATE_ERROR.rawValue: return "Operation failed"
    case GHOSTTY_PROGRESS_STATE_PAUSE.rawValue: return "Operation paused at completion"
    case GHOSTTY_PROGRESS_STATE_INDETERMINATE.rawValue: return "Operation in progress"
    default: return "Indeterminate progress"
    }
  }
}

/// Conditional wrapper: only renders the bar when libghostty has an
/// active progress report (state != REMOVE). `surface.info` is
/// `@Observable`, so reading the two fields here participates in
/// SwiftUI's invalidation graph and the bar appears/disappears as the
/// shell emits OSC 9;4.
struct PaneSurfaceProgressOverlay: View {
  let surface: PaneSurface

  var body: some View {
    if surface.info.progressState != GHOSTTY_PROGRESS_STATE_REMOVE.rawValue {
      PaneSurfaceProgressBar(
        progressState: surface.info.progressState,
        progressValue: surface.info.progressValue
      )
      .transition(.opacity)
    }
  }
}
