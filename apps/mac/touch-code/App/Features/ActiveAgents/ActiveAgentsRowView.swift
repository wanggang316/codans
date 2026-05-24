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
        AgentLogoView(kind: entry.kind, size: 20)
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
  /// (formerly on the breadcrumb) — the headline contract surface stays
  /// on the user-facing top line of the row.
  private var identityColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(worktreeName)
        .font(.callout)
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
  /// - Selected (this pane is the main window's current focus): accent
  ///   tint at low opacity — native-sidebar selection tone without
  ///   overwhelming the row chrome.
  /// - Hovering (pointer over the row): a soft gray wash so the row
  ///   feels clickable even when not selected.
  /// - Default: clear.
  /// When selected AND hovering, the selected tint wins — selection is
  /// the more semantically informative signal.
  @ViewBuilder
  private var rowBackground: some View {
    if isSelected {
      Color.accentColor.opacity(0.18)
    } else if isHovering {
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
      // Composite prompt-cursor glyph: `>` arrow + blinking `|` cursor.
      // Only the cursor blinks (matches terminal-prompt visual language;
      // "agent is waiting at the prompt for the user to type"). Reduce
      // motion keeps the cursor solid.
      PromptCursorIcon(reduceMotion: reduceMotion)
        .foregroundStyle(Color.orange)
        .accessibilityHidden(true)
    case .loading:
      // Accent (system blue by default) — reserves orange for the two
      // "needs attention" states (waitingForInput, finished-but-unread)
      // and reads loading as informational activity rather than a
      // warning. Pulses to convey "live work in progress".
      Image(systemName: "circle.fill")
        .foregroundStyle(Color.accentColor)
        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        .accessibilityHidden(true)
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

/// `> |` glyph used for the `.waitingForInput` state: a small chevron
/// followed by a 1.5pt-wide blinking caret. The caret toggles its
/// opacity on a 0.55s repeat-forever curve; reduce-motion keeps it
/// solid. Mirrors the visual language of a terminal prompt awaiting
/// input.
private struct PromptCursorIcon: View {
  let reduceMotion: Bool

  @State private var cursorOn: Bool = true

  var body: some View {
    HStack(spacing: 1.5) {
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .heavy))
      Rectangle()
        .frame(width: 1.5, height: 10)
        .opacity(cursorOn ? 1 : 0)
    }
    .frame(width: 14, height: 14, alignment: .center)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(
        .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
      ) {
        cursorOn = false
      }
    }
  }
}
