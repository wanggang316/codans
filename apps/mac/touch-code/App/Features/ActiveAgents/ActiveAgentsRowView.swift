import SwiftUI
import TouchCodeCore

/// One Agent row in the ActiveAgents sidebar panel.
///
/// Layout (current iteration per design feedback — agent name is now
/// encoded by the leading logo alone, no longer duplicated in text;
/// the relative-time column has been dropped entirely):
/// - Leading: 20pt agent logo (per-kind brand glyph via `AgentLogoView`).
/// - Center, two-line VStack:
///     · Top:    `<ProjectName>` — primary callout.
///     · Bottom: `<WorktreeName>` — caption / secondary.
/// - Trailing: state icon + short state verb in a centered HStack.
///
/// Click target is the whole row — bound to `onTap`. The host (sidebar
/// panel) intentionally does NOT collapse on tap; the row stays visible
/// after focus so the user can fan-jump between agents.
///
/// The breathing animation on `working` / `waitingForInput` icons is
/// driven by a local `@State` flag flipped in `.onAppear`; reduce-motion
/// suppresses the flip so the icon renders at full opacity statically.
struct ActiveAgentsRowView: View {
  let paneID: PaneID
  let entry: AgentRegistry.AgentEntry
  let projectName: String
  let worktreeName: String
  /// True when this row's pane is the main window's currently-focused
  /// pane. Renders a native-style selected-row tint so the user can
  /// match the row they're hovering to "the pane I'm looking at".
  /// Defaults false so older call sites that don't pass it (legacy
  /// popover view, tests) still compile.
  var isSelected: Bool = false
  let onTap: () -> Void

  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .center, spacing: 10) {
        // Logo tint darkens to `.primary` on the selected row so it
        // reads alongside the bolder title.
        AgentLogoView(kind: entry.kind, size: 20, tint: isSelected ? .primary : .secondary)
        identityColumn
        Spacer(minLength: 8)
        statusColumn
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(rowBackground)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    // `.contain` keeps the `.headline` text and `.state` icon
    // individually addressable by their sub-element identifiers (the
    // user-test contract surface — see `docs/user-tests/active-agents-view.md`).
    // `.accessibilityLabel` on a `.contain` container is a no-op, so
    // the row's full-sentence VoiceOver label is installed via
    // `.accessibilityRepresentation { Button(label, action:) }` — a
    // proxy element that carries the label without collapsing the
    // children-contain semantics needed for sub-element probing.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("activeAgents.row.\(paneID)")
    .accessibilityRepresentation {
      Button(accessibilityLabelText, action: onTap)
    }
  }

  /// Two-line identity column: worktree (branch) name on top, project
  /// name beneath. The primary line carries the
  /// `activeAgents.row.<paneID>.headline` accessibility identifier
  /// (the headline contract surface stays on the user-facing top line
  /// of the row).
  private var identityColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(worktreeName)
        .font(.callout)
        .fontWeight(isSelected ? .semibold : .regular)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier("activeAgents.row.\(paneID).headline")
      Text(projectName)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  /// Row background. Three tiers:
  /// - Selected (this pane is the main window's current focus): a
  ///   muted gray fill (per design feedback — orange is reserved for
  ///   "needs attention" / waiting state, accent blue is reserved for
  ///   progress, so selection rides on neutral grey + bolder title to
  ///   stand out).
  /// - Hovering (pointer over the row): a softer gray wash so the row
  ///   feels clickable even when not selected.
  /// - Default: clear.
  /// When selected AND hovering, the selected tint wins — selection is
  /// the more semantically informative signal.
  @ViewBuilder
  private var rowBackground: some View {
    // Selected and hovering share the same soft gray wash — selection
    // is signalled by the bolder title + darker logo (set elsewhere
    // in the row), not by a heavier background fill.
    if isSelected || isHovering {
      Color.gray.opacity(0.08)
    } else {
      Color.clear
    }
  }

  /// Trailing status column — state icon + short verb, in a single
  /// HStack that the outer row's `alignment: .center` keeps vertically
  /// centered against the two-line identity column. The state icon's
  /// `accessibilityLabel` is the raw enum value per the user-test
  /// contract (`docs/user-tests/active-agents-view.md` §Test Surface).
  private var statusColumn: some View {
    stateIcon
      .font(.caption2)
      .accessibilityElement(children: .ignore)
      .accessibilityIdentifier("activeAgents.row.\(paneID).state")
      .accessibilityLabel(entry.state.rawValue)
  }

  /// State icon glyph + color. Circle-based visual language for every
  /// state, with `.symbolEffect(.pulse)` on the two "active" states
  /// (working, waitingForInput). `.pulse` is SwiftUI 6's symbol
  /// breathing animation; routes through the symbol renderer so the
  /// animation survives the row's @Observable rebuild cycle (unlike a
  /// manual `.opacity` + `.repeatForever` chain, which restarts on
  /// every parent redraw). Color is `Color.orange` to match the
  /// inbox bell unread tint (same warning hue across the chrome).
  @ViewBuilder
  private var stateIcon: some View {
    switch entry.state {
    case .waitingForInput:
      // Pause-fill glyph — terminal-style "agent has paused for you".
      // Static (no pulse) per design feedback; the orange tint alone
      // carries the "needs your attention" signal. `.imageScale(.large)`
      // bumps the SF Symbol up roughly one tier above the surrounding
      // caption2 font so the icon reads at the same visual weight as
      // the 16pt LoadingGridIcon used for the working state.
      Image(systemName: "pause.fill")
        .imageScale(.large)
        .foregroundStyle(Color.orange)
        .accessibilityHidden(true)
    case .loading:
      // Nine-square activity grid — staggered fade-out per cell on a 3 s
      // cycle (bottom-left first → top-right last) reads as "filling in
      // progress" rather than a generic spinner. Reduce motion holds
      // every cell at full opacity. Tint follows `.primary` so the grid
      // is black in light mode / white in dark mode, distinct from the
      // orange "waiting" icon without competing visually for attention.
      LoadingGridIcon(size: 16, isAnimating: !reduceMotion)
        .foregroundStyle(.primary)
    case .finished:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityHidden(true)
    case .idle:
      Image(systemName: "circle.dashed")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }

  /// Human-readable verb for the visible inline state label
  /// ("working" / "idle" / "waiting" / "finished"). The short form
  /// keeps the trailing column compact — the spoken VoiceOver label
  /// uses the long form via `sentenceVerb`.
  private var stateVerb: String {
    switch entry.state {
    case .waitingForInput: return "waiting"
    case .loading: return "working"
    case .finished: return "finished"
    case .idle: return "idle"
    }
  }

  /// Long-form sentence verb used in the row's VoiceOver label.
  /// "waiting for input" reads naturally when chained after the
  /// `<DisplayName>, <Project>, <Worktree>` prefix.
  private var sentenceVerb: String {
    switch entry.state {
    case .waitingForInput: return "waiting for input"
    case .loading: return "working"
    case .finished: return "finished"
    case .idle: return "idle"
    }
  }

  /// Full-sentence accessibility label combining display name,
  /// worktree (top line), project (bottom line), and state. Agent name
  /// is dropped from the visible row but kept here so VoiceOver still
  /// announces which kind of agent occupies the pane.
  private var accessibilityLabelText: String {
    "\(entry.kind.displayName), \(worktreeName), \(projectName), \(sentenceVerb)"
  }
}

/// 3×3 activity-grid glyph used for the `.loading` state: nine 4-unit
/// squares on a 24-unit canvas, each fading from full opacity to 0
/// over 90 % of a 3 s cycle (then holding at 0 for 10 % before the
/// next cycle starts). Stagger goes bottom-left → top-right with
/// 0.2 s steps so the diagonal reads as the work "filling up".
/// Mirrors the SVG with `<animate>` attribute provided in the
/// design feedback. Reduce motion holds every cell at full opacity.
private struct LoadingGridIcon: View {
  let size: CGFloat
  let isAnimating: Bool

  /// Begin offsets matching the SVG, indexed `[row][col]` with row 0
  /// = top row. The SVG starts the animation at the bottom-left
  /// (begin 0.2 s) and walks up rightward.
  private static let beginOffsets: [[Double]] = [
    [1.4, 1.6, 1.8],
    [0.8, 1.0, 1.2],
    [0.2, 0.4, 0.6],
  ]
  private static let cycle: Double = 3.0

  var body: some View {
    // SVG geometry: 4-pt squares with 2-pt gutters in a 24-pt
    // viewBox. Translate to a `size`-pt rendered glyph.
    let cell = size * (4.0 / 24.0)
    let gap = size * (2.0 / 24.0)
    TimelineView(
      .animation(minimumInterval: 1.0 / 30.0, paused: !isAnimating)
    ) { context in
      let now = context.date.timeIntervalSinceReferenceDate
      VStack(spacing: gap) {
        ForEach(0..<3, id: \.self) { row in
          HStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { col in
              Rectangle()
                .frame(width: cell, height: cell)
                .opacity(isAnimating ? opacity(now: now, row: row, col: col) : 1.0)
            }
          }
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  /// Linear fade from 1 → 0 across the first 90 % of the 3 s cycle,
  /// then pinned at 0 for the last 10 %, matching the SVG's
  /// `values="1;0;0"` over `keyTimes="0;0.9;1"`.
  private func opacity(now: Double, row: Int, col: Int) -> Double {
    let begin = Self.beginOffsets[row][col]
    let elapsed = now - begin
    // Before the begin offset on the first cycle, SVG shows the cell
    // at full opacity (default fill). Compute the phase modulo `cycle`
    // so the wraparound case continues looping after the first cycle.
    let phase = elapsed >= 0
      ? elapsed.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
      : 0.0
    if phase < 0.9 {
      return 1.0 - (phase / 0.9)
    } else {
      return 0.0
    }
  }
}
