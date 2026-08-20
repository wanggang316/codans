import CodansCore
import SwiftUI

/// Hover summary card for one Agents View row — a quick, self-contained
/// peek at the agent session behind the row so the user can triage
/// without focusing the pane.
///
/// The card earns its place with content the row cannot carry: the
/// session *task* (the first user prompt of the worktree's latest
/// session for this agent, via the same scanners the tab bar's resume
/// popover uses) and the live *activity* (the pane's OSC title, shown
/// only when it says more than the agent's own name — idle agents
/// retitle the pane to themselves, which reads as noise here).
///
/// Layout (top → bottom):
/// - Header: agent logo + display name, state glyph + verb trailing.
/// - Breadcrumb: `<project> / <worktree>` (project in its configured hue),
///   with the elapsed time since the last state transition pinned to the
///   trailing edge, ticking once a second via `TimelineView`.
/// - Session block (after the scan lands, hidden when the worktree has
///   no session for this agent kind): session title, optional activity
///   line, then `<short id> · <relative age>`.
///
/// Until the pane carries a real `agentSessionID` the session block is a
/// most-recent approximation: the newest on-disk session of this agent
/// kind in this worktree. When the binder starts writing session ids the
/// exact-match preference in `AgentSummaryCardFormat.latestSession`
/// takes over automatically.
///
/// Presentation (hover-in delay, popover anchoring, dismissal) is owned
/// by `AgentStateRowView`; this view is pure content.
struct AgentSessionSummaryCard: View {
  let entry: AgentStateStore.AgentEntry
  let projectName: String
  let worktreeName: String
  var projectColor: ProjectColor?
  /// Worktree filesystem path — the session scanners' lookup key. nil
  /// (legacy call sites, torn-down panes) skips the scan entirely.
  var worktreePath: String?
  /// Non-nil for Server (remote) projects: session stores live in the
  /// HOST's home, so the scan goes over SSH.
  var remoteHost: RemoteHost?
  /// Latest OSC title of the row's pane. Called lazily on each render
  /// so the activity line stays live while the card is open.
  let paneTitle: () -> String?

  /// Newest matching on-disk session, populated by the scan task. Stays
  /// nil while scanning and when the worktree has none — both render as
  /// "no session block" rather than a loading placeholder, so the card
  /// never pops open with a spinner for what is a glanceable peek.
  @State private var session: AgentSessionSummary?

  /// Mirrors the tab bar's session-row formatter (`.short` units) so
  /// ages read identically in both surfaces. Static — one CFLocale/ICU
  /// spin-up per process, not per hover.
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
  }()

  var body: some View {
    let activity = activityTitle
    VStack(alignment: .leading, spacing: 8) {
      header
      breadcrumb
      if session != nil || activity != nil {
        Divider()
      }
      if let session {
        Text(session.title)
          .font(.caption)
          .foregroundStyle(.primary)
          .lineLimit(2)
          .truncationMode(.tail)
          .accessibilityIdentifier("agentState.summaryCard.sessionTitle")
      }
      if let activity {
        activityLine(activity)
      }
      if let session {
        sessionFooter(session)
      }
    }
    .padding(12)
    .frame(width: 320, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agentState.summaryCard")
    .task {
      guard let path = worktreePath else { return }
      // Server-project worktrees keep their session stores in the host's
      // home — scan over SSH; local worktrees stat + prefix-read dozens
      // of files, so that runs on a detached task off the main actor.
      // Mirrors AgentSessionHistoryPopover's scan dispatch.
      let groups: [AgentSessionGroup]
      if let host = remoteHost {
        groups = await RemoteAgentSessionHistoryScanner.scan(host: host, worktreePath: path)
      } else {
        groups = await Task.detached(priority: .userInitiated) {
          AgentSessionHistoryScanner.scan(worktreePath: path)
        }.value
      }
      session = AgentSummaryCardFormat.latestSession(
        in: groups, kind: entry.kind, preferredID: entry.sessionID
      )
    }
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

  /// Pane title worth showing: trimmed, non-empty, and saying more than
  /// the agent's own name (idle agents set the title to themselves).
  private var activityTitle: String? {
    guard
      let raw = paneTitle()?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty,
      !AgentSummaryCardFormat.isRedundantActivityTitle(
        raw, agentDisplayName: entry.kind.displayName
      )
    else { return nil }
    return raw
  }

  private func activityLine(_ title: String) -> some View {
    Text(title)
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityIdentifier("agentState.summaryCard.activity")
  }

  /// `<short id> · <relative age>` — same vocabulary as the tab bar's
  /// session rows so the two surfaces cross-reference naturally.
  private func sessionFooter(_ session: AgentSessionSummary) -> some View {
    HStack(spacing: 6) {
      Text(session.shortSessionID)
        .monospaced()
      Text("·")
      Text(Self.relativeFormatter.localizedString(for: session.updatedAt, relativeTo: Date()))
    }
    .font(.caption2)
    .foregroundStyle(.tertiary)
    .accessibilityIdentifier("agentState.summaryCard.sessionMeta")
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

  /// True when an OSC title carries no information beyond the agent's
  /// display name — idle agents typically retitle the pane to themselves
  /// (`Claude Code`, `✳ Claude Code`). Leading decoration (spinner
  /// glyphs, punctuation, whitespace) is stripped before the
  /// case-insensitive comparison; anything longer than the bare name
  /// (e.g. "✳ Claude Code · fixing tests") is information and stays.
  static func isRedundantActivityTitle(_ title: String, agentDisplayName: String) -> Bool {
    var stripped = Substring(title)
    while let first = stripped.first, !first.isLetter, !first.isNumber {
      stripped.removeFirst()
    }
    return stripped.trimmingCharacters(in: .whitespaces)
      .caseInsensitiveCompare(agentDisplayName) == .orderedSame
  }

  /// The session to feature on the card. Exact id match wins wherever it
  /// lives (ready for the binder landing real session ids); otherwise
  /// the newest session of `kind` — groups arrive with sessions already
  /// newest-first per the scanner's contract, but re-sort defensively
  /// since this helper is the card's single correctness point.
  static func latestSession(
    in groups: [AgentSessionGroup],
    kind: AgentKind,
    preferredID: String?
  ) -> AgentSessionSummary? {
    let all = groups.flatMap(\.sessions)
    if let preferredID, let exact = all.first(where: { $0.sessionID == preferredID }) {
      return exact
    }
    return
      all
      .filter { $0.agent == kind }
      .max(by: { $0.updatedAt < $1.updatedAt })
  }
}
