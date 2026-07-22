import CodansCore
import SwiftUI

/// Hover summary card for one Agents View row — a quick, self-contained
/// peek at the agent session behind the row so the user can triage
/// without focusing the pane.
///
/// Layout (top → bottom):
/// - Header: agent logo + display name, state glyph + verb trailing.
/// - Breadcrumb: `<project> / <worktree>` (project in its configured hue).
/// - Status line: `<Verb> · <duration since last transition>`, ticking
///   once a second via `TimelineView` while the card stays open.
/// - Session line: the agent's own session id when one was captured
///   (hidden otherwise — most binders don't model it yet).
/// - Terminal tail: the last few non-blank lines of the pane's rendered
///   viewport, monospaced. `viewportSnapshot` is called on every render
///   pass, so an open card tracks the live viewport as the agent works.
///
/// Presentation (hover-in delay, popover anchoring, dismissal) is owned
/// by `AgentStateRowView`; this view is pure content.
struct AgentSessionSummaryCard: View {
  let entry: AgentStateStore.AgentEntry
  let projectName: String
  let worktreeName: String
  var projectColor: ProjectColor?
  /// Latest rendered viewport text for the row's pane. Called lazily on
  /// each render so the tail stays live while the card is open.
  let viewportSnapshot: () -> String?

  var body: some View {
    let tail = AgentSessionSummary.tailLines(viewportSnapshot())
    VStack(alignment: .leading, spacing: 8) {
      header
      breadcrumb
      statusLine
      if let sessionID = entry.sessionID {
        sessionLine(sessionID)
      }
      if !tail.isEmpty {
        Divider()
        terminalTail(tail)
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
  /// configured hue (matching the row's project caption), worktree
  /// carries the primary weight since it names the working copy.
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
    }
  }

  /// `<Verb> · <duration>` since the last state transition, refreshed
  /// once a second so a card left open doesn't show a stale age.
  private var statusLine: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      Text(
        "\(entry.state.rawValue.capitalized) · "
          + AgentSessionSummary.durationText(from: entry.lastTransitionAt, to: context.date)
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("agentState.summaryCard.status")
    }
  }

  private func sessionLine(_ sessionID: String) -> some View {
    Text("Session \(sessionID)")
      .font(.caption2)
      .foregroundStyle(.tertiary)
      .lineLimit(1)
      .truncationMode(.middle)
  }

  private func terminalTail(_ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        Text(line)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(8)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("agentState.summaryCard.tail")
  }
}

/// Pure formatting helpers for the summary card, kept off the view so
/// they stay unit-testable without rendering.
nonisolated enum AgentSessionSummary {
  /// Last `maxLines` non-blank lines of a rendered viewport, each
  /// whitespace-trimmed. Blank lines are dropped entirely — the card is
  /// a density-first peek, not a faithful terminal replica.
  static func tailLines(_ text: String?, maxLines: Int = 8) -> [String] {
    guard let text else { return [] }
    let lines =
      text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    return Array(lines.suffix(maxLines))
  }

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
