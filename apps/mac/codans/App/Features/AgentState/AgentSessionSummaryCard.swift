import CodansCore
import SwiftUI

/// Hover summary card for one Agents View row — a quick, self-contained
/// peek at the agent session behind the row so the user can triage
/// without focusing the pane.
///
/// Pure metadata, no terminal stream: a raw viewport tail proved too
/// noisy for a small floating card (truncated TUI lines carry little),
/// so the "what is it doing" role moved to the pane's OSC title — the
/// one-liner agents themselves keep current as they work.
///
/// Layout (top → bottom):
/// - Header: agent logo + display name, state glyph + verb trailing.
/// - Breadcrumb: `<project> / <worktree>` (project in its configured hue),
///   with the elapsed time since the last state transition pinned to the
///   trailing edge — directly under the state chip it qualifies, ticking
///   once a second via `TimelineView` while the card stays open.
/// - Activity line: the pane's latest OSC title. `paneTitle` is called
///   on every render pass, so an open card tracks retitles live; the
///   line collapses entirely while no usable title has been observed.
/// - Session line: the agent's own session id when one was captured
///   (hidden otherwise — most binders don't model it yet).
///
/// Presentation (hover-in delay, popover anchoring, dismissal) is owned
/// by `AgentStateRowView`; this view is pure content.
struct AgentSessionSummaryCard: View {
  let entry: AgentStateStore.AgentEntry
  let projectName: String
  let worktreeName: String
  var projectColor: ProjectColor?
  /// Latest OSC title of the row's pane. Called lazily on each render
  /// so the activity line stays live while the card is open.
  let paneTitle: () -> String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      breadcrumb
      if let title = trimmedTitle {
        activityLine(title)
      }
      if let sessionID = entry.sessionID {
        sessionLine(sessionID)
      }
    }
    .padding(12)
    .frame(width: 320, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agentState.summaryCard")
  }

  private var header: some View {
    HStack(spacing: 8) {
      AgentLogoView(kind: entry.kind, size: 18, tint: .primary)
      Text(entry.kind.displayName)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
      Spacer(minLength: 8)
      stateChip
    }
  }

  /// State glyph + verb, mirroring the row's color language: orange for
  /// blocked, primary for working, green for finished, secondary for idle.
  private var stateChip: some View {
    HStack(spacing: 4) {
      Image(systemName: stateGlyphName)
        .imageScale(.small)
        .foregroundStyle(stateColor)
        .accessibilityHidden(true)
      Text(entry.state.rawValue)
        .font(.caption)
        .foregroundStyle(stateColor)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(entry.state.rawValue)
    .accessibilityIdentifier("agentState.summaryCard.state")
  }

  private var stateGlyphName: String {
    switch entry.state {
    case .blocked: return "pause.fill"
    case .working: return "square.grid.3x3.fill"
    case .finished: return "checkmark.circle.fill"
    case .idle: return "circle.dashed"
    }
  }

  private var stateColor: Color {
    switch entry.state {
    case .blocked: return .orange
    case .working: return .primary
    case .finished: return .green
    case .idle: return .secondary
    }
  }

  /// `<project> / <worktree>` on one line — project leads in its
  /// configured hue (matching the row's project caption). The elapsed
  /// time since the last state transition sits at the trailing edge,
  /// right under the state chip it qualifies, refreshed once a second
  /// so a card left open doesn't show a stale age.
  private var breadcrumb: some View {
    HStack(spacing: 4) {
      Text(projectName)
        .font(.caption)
        .foregroundStyle(projectColor?.swiftUIColor ?? .secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Text("/")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Text(worktreeName)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(AgentSummaryCardFormat.durationText(from: entry.lastTransitionAt, to: context.date))
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("agentState.summaryCard.duration")
      }
    }
  }

  /// Pane title with surrounding whitespace stripped; nil when the
  /// terminal has not pushed a usable title, so the activity line
  /// disappears instead of rendering an empty row.
  private var trimmedTitle: String? {
    guard
      let raw = paneTitle()?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else { return nil }
    return raw
  }

  private func activityLine(_ title: String) -> some View {
    Text(title)
      .font(.caption)
      .foregroundStyle(.primary)
      .lineLimit(2)
      .truncationMode(.tail)
      .accessibilityIdentifier("agentState.summaryCard.activity")
  }

  private func sessionLine(_ sessionID: String) -> some View {
    Text("Session \(sessionID)")
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .lineLimit(1)
      .truncationMode(.middle)
  }
}

/// Pure formatting helpers for the summary card, kept off the view so
/// they stay unit-testable without rendering.
nonisolated enum AgentSummaryCardFormat {
  /// Compact elapsed-time label: "42s", "12m", "1h 3m", "2d". Clamped
  /// at zero so a clock skew between `lastTransitionAt` and the render
  /// date can't produce a negative age.
  static func durationText(from start: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 24 {
      let remainder = minutes % 60
      return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
    return "\(hours / 24)d"
  }
}
