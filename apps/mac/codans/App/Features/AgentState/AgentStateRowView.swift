import CodansCore
import SwiftUI

/// One Agent row in the AgentState sidebar panel.
///
/// Layout:
/// - Leading: 20pt agent logo (per-kind brand glyph via `AgentLogoView`).
/// - Center, by density:
///     · `normal`: the agent activity text (else the agent display name)
///       over the identity line `<WorktreeName> <ProjectName>`.
///     · `compact`: the identity line alone.
/// - Trailing: sleep glyph (when sleeping) + state icon.
///
/// Click target is the whole row — bound to `onTap`. The host (sidebar
/// panel) intentionally does NOT collapse on tap; the row stays visible
/// after focus so the user can fan-jump between agents.
///
/// The breathing animation on `working` / `blocked` icons is
/// driven by a local `@State` flag flipped in `.onAppear`; reduce-motion
/// suppresses the flip so the icon renders at full opacity statically.
struct AgentStateRowView: View {
  let paneID: PaneID
  let entry: AgentStateStore.AgentEntry
  let projectName: String
  let worktreeName: String
  /// The source project's configured color. When set, the project line
  /// renders in this hue so the row matches the sidebar header and
  /// worktree-header label; `nil` (No Color) keeps the caption secondary.
  /// Defaults to `nil` so legacy call sites and tests render unchanged.
  var projectColor: ProjectColor?
  /// Non-nil for a Server (remote) project: the host's display authority
  /// (`user@host[:port]`). The project line grows the same wifi-badged glyph
  /// the sidebar project row wears, with the authority as its tooltip, so a
  /// remote agent is recognizable at a glance. Defaults nil so legacy call
  /// sites and tests render unchanged.
  var projectRemoteAuthority: String?
  /// True when this row's pane is the main window's currently-focused
  /// pane. Renders a native-style selected-row tint so the user can
  /// match the row they're hovering to "the pane I'm looking at".
  /// Defaults false so older call sites that don't pass it (legacy
  /// view, tests) still compile.
  var isSelected: Bool = false
  /// True when no surface renders this row's pane: the agent still runs in
  /// its daemon, but the app does not observe it, so `entry.state` is the
  /// last known one. Draws a sleep glyph before the state icon. Defaults
  /// false so legacy call sites and tests render unchanged.
  var isSleeping: Bool = false
  /// Row density — `normal` keeps the two-line identity column;
  /// `compact` joins worktree and project on one line and tightens
  /// vertical padding. Defaults to `.normal` so the legacy default
  /// caller and tests render unchanged without opt-in.
  var displayMode: AgentsViewDisplayMode = .normal
  /// Live agent activity text of this row's pane (OSC 7501 `message`, else
  /// the OSC 0/2 title), shown on the first line in `normal` density. Read
  /// only inside `AgentActivityLine` so updates re-render that line alone.
  /// Defaults to nil-returning so legacy call sites (popover variant,
  /// tests) show the agent display name.
  var activityText: () -> String? = { nil }
  /// The row's bound focus chord (`⌥N`). Takes the trailing status glyphs' place
  /// while ⌘ is held.
  var hotkeyHint: String?
  let onTap: () -> Void
  /// Context-menu "Hand Off…" for this row's pane. Optional so legacy call
  /// sites and tests render the row without a menu.
  var onHandOff: (() -> Void)?
  /// Workflows this row's pane could start as the `current` role, for the
  /// context menu's "Run Workflow" submenu. Empty hides the submenu.
  var workflows: [(id: String, name: String, isValid: Bool)] = []
  var onRunWorkflow: ((String) -> Void)?

  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      // Logo tint darkens to `.primary` on the selected row — the
      // primary visual signal that this row is the current focus.
      AgentLogoView(kind: entry.kind, size: 20, tint: isSelected ? .primary : .secondary)
      identityColumn
      // A greedy spacer pins the status icon to the row's trailing
      // edge in both densities, so the state glyph reads as a single
      // right-aligned column down the list rather than floating at a
      // variable offset after each project name.
      Spacer(minLength: 8)
      ShortcutHintTrailing(chord: hotkeyHint) {
        HStack(alignment: .center, spacing: 10) {
          if isSleeping {
            sleepGlyph
          }
          statusColumn
        }
      }
    }
    .padding(.horizontal, 12)
    // Compact mode tightens the row to roughly two-thirds of the
    // normal vertical padding so a single-line identity reads as
    // genuinely denser, not just one line collapsed into the same
    // height.
    .padding(.vertical, displayMode == .compact ? 4 : 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(rowBackground)
    // Not a `Button`: a button merges its label's texts into one element,
    // which hides the `.headline` / `.activity` / `.state` leaves. Keep what
    // the button gave keyboard users: with keyboard navigation on, Tab
    // focuses the row (a click does not) and Space or Return activates it.
    .onTapGesture(perform: handleTap)
    .focusable(interactions: .activate)
    .onKeyPress(keys: [.space, .return]) { _ in
      handleTap()
      return .handled
    }
    .contextMenu {
      if let onHandOff {
        Button {
          onHandOff()
        } label: {
          Label("Hand Off…", systemImage: "arrow.right.arrow.left")
        }
      }
      if let onRunWorkflow, !workflows.isEmpty {
        Menu {
          ForEach(workflows, id: \.id) { workflow in
            Button(workflow.isValid ? workflow.name : "\(workflow.name) — has errors") {
              onRunWorkflow(workflow.id)
            }
            .disabled(!workflow.isValid)
          }
        } label: {
          Label("Run Workflow", systemImage: "arrow.triangle.branch")
        }
      }
    }
    .onHover { isHovering = $0 }
    // `.contain` keeps the `.headline` / `.activity` texts and `.state` icon
    // individually addressable by their sub-element identifiers (the
    // user-test contract surface). The row group itself carries the
    // full-sentence label (without the activity text) and the press action.
    // No `.accessibilityRepresentation`: it replaces the whole subtree and
    // would hide those leaves.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agentState.row.\(paneID)")
    .accessibilityLabel(accessibilityLabelText)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(.default, handleTap)
  }

  /// Row tap focuses the pane. The focus cascade walks the catalog and
  /// re-selects project → worktree → tab → pane, which tears down and
  /// rebuilds pane surfaces; it runs on the next main-loop turn so it does
  /// not destroy views inside the click's own SwiftUI transaction.
  private func handleTap() {
    Task { @MainActor in onTap() }
  }

  /// Center column. `normal` puts the live activity line over the identity
  /// line; `compact` shows the identity line alone. A cached state dims the
  /// activity text the same as the state icon: both are the last value
  /// seen, not a live one.
  @ViewBuilder
  private var identityColumn: some View {
    switch displayMode {
    case .normal:
      VStack(alignment: .leading, spacing: 2) {
        AgentActivityLine(
          paneID: paneID,
          activityText: activityText,
          activity: AgentActivityPresentation(kind: entry.kind)
        )
        // A rebind to another agent kind starts a fresh presentation, so
        // the fallback name and the redundant-title check follow the kind.
        .id(entry.kind)
        .opacity(isStateCached ? Self.cachedOpacity : 1)
        identityLine(isSecondary: true)
      }
    case .compact:
      identityLine(isSecondary: false)
    }
  }

  /// Worktree at the leading edge, a small fixed gap, then project right
  /// after. Both share the available width — no `Spacer` or
  /// `layoutPriority` pushing one to a row edge, since a long branch name
  /// plus a forced trailing-edge project crushes the project text to a
  /// single letter. With equal priority both truncate proportionally and
  /// stay readable. The worktree text carries the
  /// `agentState.row.<paneID>.headline` identifier (the user-test contract
  /// surface) in both densities.
  ///
  /// `isSecondary` is the `normal` second line: the worktree text drops to
  /// a smaller, lighter style so the activity line above reads first.
  private func identityLine(isSecondary: Bool) -> some View {
    HStack(spacing: 8) {
      Text(worktreeName)
        .font(isSecondary ? .caption : .subheadline)
        .fontWeight(.regular)
        .foregroundStyle(isSecondary ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier("agentState.row.\(paneID).headline")
      HStack(spacing: 3) {
        Text(projectName)
          .font(.caption2)
          .foregroundStyle(projectNameStyle)
          .lineLimit(1)
          .truncationMode(.middle)
        remoteGlyph
      }
    }
  }

  /// Remote Project marker after the project name. Empty for local projects.
  @ViewBuilder
  private var remoteGlyph: some View {
    if let authority = projectRemoteAuthority {
      Image(systemName: RemoteProjectMarker.symbol)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help(authority)
        .accessibilityLabel("Remote host \(authority)")
    }
  }

  /// Foreground color for the project line. Uses the project's configured
  /// color when set; falls back to the caption `.secondary` hue for No-Color
  /// projects so the row reads unchanged from before this affordance.
  private var projectNameStyle: Color {
    projectColor?.swiftUIColor ?? .secondary
  }

  /// Row background. Three tiers:
  /// - Selected (this pane is the main window's current focus): a
  ///   muted gray fill (per design feedback — orange is reserved for
  ///   "needs attention" / waiting state, accent blue is reserved for
  ///   progress, so selection rides on neutral grey + a darker logo
  ///   tint to stand out).
  /// - Hovering (pointer over the row): a softer gray wash so the row
  ///   feels clickable even when not selected.
  /// - Default: clear.
  /// When selected AND hovering, the selected tint wins — selection is
  /// the more semantically informative signal.
  @ViewBuilder
  private var rowBackground: some View {
    // Selected and hovering share the same soft gray wash — selection
    // is signalled by the darker logo tint (set elsewhere in the row),
    // not by a heavier background fill.
    if isSelected || isHovering {
      Color.gray.opacity(0.08)
    } else {
      Color.clear
    }
  }

  /// Sleep marker for a pane no surface renders. Semibold compensates for
  /// the thin strokes of the zzz glyph next to the filled state icons.
  private var sleepGlyph: some View {
    Image(systemName: "zzz")
      .font(.caption2)
      .fontWeight(.semibold)
      .imageScale(.small)
      .foregroundStyle(.secondary)
      .help("Sleeping to save resources. Click to wake.")
      .accessibilityIdentifier("agentState.row.\(paneID).sleeping")
      .accessibilityLabel("Sleeping")
  }

  private var isStateCached: Bool { entry.source == .cached }
  private static let cachedOpacity = 0.45

  /// Trailing status column — state icon + short verb, in a single
  /// HStack that the outer row's `alignment: .center` keeps vertically
  /// centered against the two-line identity column. The state icon's
  /// `accessibilityLabel` is the raw enum value per the user-test contract.
  ///
  /// A cached state (no surface, and no program status report through the
  /// passive watcher) is the last one seen, not a live one: the icon is
  /// dimmed and does not animate, so a restored `working` does not read as
  /// work in progress.
  private var statusColumn: some View {
    stateIcon
      .font(.caption2)
      .opacity(isStateCached ? Self.cachedOpacity : 1)
      .help(isStateCached ? "Last known state. Click to wake and update it." : "")
      .accessibilityElement(children: .ignore)
      .accessibilityIdentifier("agentState.row.\(paneID).state")
      .accessibilityLabel(entry.state.rawValue)
  }

  /// State icon glyph + color. Circle-based visual language for every
  /// state. Color is `Color.orange` to match the inbox bell unread tint
  /// (same warning hue across the chrome).
  @ViewBuilder
  private var stateIcon: some View {
    switch entry.state {
    case .blocked:
      // Raised-hand glyph — "agent is waiting for your input".
      // Static (no pulse) per design feedback; the orange tint alone
      // carries the "needs your attention" signal. `.imageScale(.large)`
      // bumps the SF Symbol up roughly one tier above the surrounding
      // caption2 font so the icon reads at the same visual weight as
      // the 16pt LoadingGridIcon used for the working state.
      Image(systemName: "hand.raised.fill")
        .imageScale(.large)
        .foregroundStyle(Color.orange)
        .accessibilityHidden(true)
    case .working:
      // Nine-square activity grid — staggered fade-out per cell on a 3 s
      // cycle (bottom-left first → top-right last) reads as "filling in
      // progress" rather than a generic spinner. Reduce motion holds
      // every cell at full opacity. Tint follows `.primary` so the grid
      // is black in light mode / white in dark mode, distinct from the
      // orange "blocked" icon without competing visually for attention.
      LoadingGridIcon(size: 16, isAnimating: !reduceMotion && !isStateCached)
        .foregroundStyle(.primary)
    case .done:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityHidden(true)
    case .error:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
    case .idle:
      Image(systemName: "circle.dashed")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }

  /// Human-readable verb for the visible inline state label
  /// ("idle" / "working" / "blocked" / "done" / "error"). The short form
  /// keeps the trailing column compact — the spoken VoiceOver label
  /// uses the long form via `sentenceVerb`.
  private var stateVerb: String {
    switch entry.state {
    case .blocked: return "blocked"
    case .working: return "working"
    case .done: return "done"
    case .error: return "error"
    case .idle: return "idle"
    }
  }

  /// Long-form sentence verb used in the row's VoiceOver label, chained
  /// after the `<DisplayName>, <Project>, <Worktree>` prefix.
  private var sentenceVerb: String {
    switch entry.state {
    case .blocked: return "blocked"
    case .working: return "working"
    case .done: return "done"
    case .error: return "failed"
    case .idle: return "idle"
    }
  }

  /// Full-sentence accessibility label combining display name, worktree,
  /// project, and state. The activity text is left out: it changes too
  /// often for a label VoiceOver reads on focus.
  private var accessibilityLabelText: String {
    "\(entry.kind.displayName), \(worktreeName), \(projectName), \(sentenceVerb)" + (isSleeping ? ", sleeping" : "")
  }
}

/// 3×3 activity-grid glyph used for the `.working` state: nine 4-unit
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
    let phase =
      elapsed >= 0
      ? elapsed.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle
      : 0.0
    if phase < 0.9 {
      return 1.0 - (phase / 0.9)
    } else {
      return 0.0
    }
  }
}
