import CodansCore
import SwiftUI

/// Session metadata resolved before presentation, so asynchronous scans cannot
/// resize an open popover. Activity is captured for the initial frame, then
/// updated independently inside a permanently reserved single-line slot.
/// See docs/lessons-learned/2026-08-20-agents-view-row-click-segfault-in-popover.md.
struct AgentSessionSummarySnapshot: Identifiable, Equatable {
  /// The row's pane. Doubles as the popover item identity, so a card
  /// captured for one row can never be reused for another.
  let id: PaneID
  let entry: AgentStateStore.AgentEntry
  let projectName: String
  let worktreeName: String
  let projectColor: ProjectColor?
  /// Featured session for this row, resolved before presentation. nil
  /// when the worktree has none for this agent kind (or no path to scan)
  /// — the card then renders without a session block.
  let session: AgentSessionSummary?
  /// Pane OSC title worth showing, or nil when it carries nothing beyond
  /// the agent's own name.
  let activity: String?
  /// Elapsed time since `entry.lastTransitionAt`, formatted at capture.
  let ageText: String
  /// Relative age of `session.updatedAt`, formatted at capture.
  let sessionAgeText: String?

  /// Mirrors the tab bar's session-row formatter (`.short` units) so ages
  /// read identically in both surfaces. Static — one CFLocale/ICU
  /// spin-up per process, not per hover.
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter
  }()

  init(
    paneID: PaneID,
    entry: AgentStateStore.AgentEntry,
    projectName: String,
    worktreeName: String,
    projectColor: ProjectColor?,
    session: AgentSessionSummary?,
    paneTitle: String?,
    now: Date = Date()
  ) {
    self.id = paneID
    self.entry = entry
    self.projectName = projectName
    self.worktreeName = worktreeName
    self.projectColor = projectColor
    self.session = session
    self.activity = AgentSummaryCardFormat.activityLine(from: paneTitle, kind: entry.kind)
    self.ageText = AgentSummaryCardFormat.durationText(from: entry.lastTransitionAt, to: now)
    self.sessionAgeText = session.map {
      Self.relativeFormatter.localizedString(for: $0.updatedAt, relativeTo: now)
    }
  }

  /// Build a row's card payload, resolving the featured session first.
  ///
  /// Server-project worktrees keep their session stores in the host's
  /// home — scan over SSH; local worktrees stat + prefix-read dozens of
  /// files, so that runs on a detached task off the main actor. Mirrors
  /// `AgentSessionHistoryPopover`'s scan dispatch. A nil `worktreePath`
  /// (legacy call sites, torn-down panes) skips the scan.
  static func make(
    paneID: PaneID,
    entry: AgentStateStore.AgentEntry,
    projectName: String,
    worktreeName: String,
    projectColor: ProjectColor?,
    worktreePath: String?,
    remoteHost: RemoteHost?,
    paneTitle: String?
  ) async -> AgentSessionSummarySnapshot {
    var featured: AgentSessionSummary?
    if let path = worktreePath {
      let groups: [AgentSessionGroup]
      if let host = remoteHost {
        groups = await RemoteAgentSessionHistoryScanner.scan(host: host, worktreePath: path)
      } else {
        groups = await Task.detached(priority: .userInitiated) {
          AgentSessionHistoryScanner.scan(worktreePath: path)
        }.value
      }
      featured = AgentSummaryCardFormat.latestSession(
        in: groups, kind: entry.kind, preferredID: entry.sessionID
      )
    }
    return AgentSessionSummarySnapshot(
      paneID: paneID,
      entry: entry,
      projectName: projectName,
      worktreeName: worktreeName,
      projectColor: projectColor,
      session: featured,
      paneTitle: paneTitle
    )
  }
}

/// Hover summary card for one Agents View row — a quick, self-contained
/// peek at the agent session behind the row so the user can triage
/// without focusing the pane.
///
/// The card earns its place with content the row cannot carry: the
/// session *task* (the first user prompt of the worktree's latest
/// session for this agent, via the same scanners the tab bar's resume
/// popover uses) and the *activity* (the pane's OSC title, shown only
/// when it says more than the agent's own name — idle agents retitle the
/// pane to themselves, which reads as noise here).
///
/// Layout (top → bottom):
/// - Header: agent logo + display name, state glyph + verb trailing.
/// - Breadcrumb: `<project> / <worktree>` (project in its configured hue),
///   with the elapsed time since the last state transition pinned to the
///   trailing edge.
/// - Session block (hidden when the worktree has no session for this
///   agent kind): session title, reserved activity line, then
///   `<short id> · <relative age>`.
///
/// Until the pane carries a real `agentSessionID` the session block is a
/// most-recent approximation: the newest on-disk session of this agent
/// kind in this worktree. When the binder starts writing session ids the
/// exact-match preference in `AgentSummaryCardFormat.latestSession`
/// takes over automatically.
///
/// Session metadata stays frozen at hover time. Only the activity slot observes
/// live titles; its fixed height prevents animated popover-window resizing.
/// Presentation (hover-in delay, popover anchoring, dismissal) is owned
/// by `AgentStateRowView`; this view is pure content.
struct AgentSessionSummaryCard: View {
  let snapshot: AgentSessionSummarySnapshot
  let paneTitle: () -> String?

  private var entry: AgentStateStore.AgentEntry { snapshot.entry }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      breadcrumb
      Divider()
      if let session = snapshot.session {
        Text(session.title)
          .font(.caption)
          .foregroundStyle(.primary)
          .lineLimit(2)
          .truncationMode(.tail)
          .accessibilityIdentifier("agentState.summaryCard.sessionTitle")
      }
      AgentSessionActivityLine(
        paneTitle: paneTitle,
        activity: AgentActivityPresentation(title: snapshot.activity, kind: entry.kind)
      )
      if let session = snapshot.session {
        sessionFooter(session)
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
  /// right under the state chip it qualifies, frozen at hover time.
  private var breadcrumb: some View {
    HStack(spacing: 4) {
      Text(snapshot.projectName)
        .font(.caption)
        .foregroundStyle(snapshot.projectColor?.swiftUIColor ?? .secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Text("/")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Text(snapshot.worktreeName)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Text(snapshot.ageText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("agentState.summaryCard.duration")
    }
  }

  /// `<short id> · <relative age>` — same vocabulary as the tab bar's
  /// session rows so the two surfaces cross-reference naturally.
  private func sessionFooter(_ session: AgentSessionSummary) -> some View {
    HStack(spacing: 6) {
      Text(session.shortSessionID)
        .monospaced()
      Text("·")
      Text(snapshot.sessionAgeText ?? "")
    }
    .font(.caption2)
    .foregroundStyle(.tertiary)
    .accessibilityIdentifier("agentState.summaryCard.sessionMeta")
  }
}

/// Read the observable title cache here, rather than in the row or the whole
/// card. The slot remains present even when the title is empty or redundant.
struct AgentSessionActivityLine: View {
  let paneTitle: () -> String?
  @State var activity: AgentActivityPresentation

  var body: some View {
    Text(activity.text ?? " ")
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 16)
      .clipped()
      .accessibilityHidden(activity.text == nil)
      .accessibilityIdentifier("agentState.summaryCard.activity")
      .onChange(of: paneTitle(), initial: true) { _, title in
        activity.update(title: title)
      }
      .onDisappear { activity.cancel() }
  }
}

/// Pure formatting helpers for the summary card, kept off the view so
/// they stay unit-testable without rendering.
nonisolated enum AgentSummaryCardFormat {
  /// Pane title worth showing: trimmed, non-empty, and saying more than
  /// the agent's own name (idle agents set the title to themselves).
  static func activityLine(from title: String?, kind: AgentKind) -> String? {
    guard
      let raw = title?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty,
      !AgentSummaryCardFormat.isRedundantActivityTitle(raw, agentDisplayName: kind.displayName)
    else { return nil }
    return raw
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
