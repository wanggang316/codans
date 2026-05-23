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
  let onTap: () -> Void

  @State private var isHovering = false
  /// Drives the breathing opacity pulse on active states (working /
  /// waitingForInput). Flipped once in `.onAppear` so SwiftUI's
  /// `repeatForever` chain finds a value change to anchor against.
  @State private var pulseActive = false
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
      .background(isHovering ? Color.gray.opacity(0.08) : Color.clear)
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
    .onAppear {
      if !reduceMotion { pulseActive = true }
    }
  }

  /// Two-line identity column: project name on top, worktree name
  /// beneath. The bottom line keeps the `activeAgents.row.<paneID>.headline`
  /// accessibility identifier the user-test contract depends on, even
  /// though the visible breadcrumb shape has changed.
  private var identityColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(projectName)
        .font(.callout)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(worktreeName)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityIdentifier("activeAgents.row.\(paneID).headline")
    }
  }

  /// Trailing status column — state icon + short verb, in a single
  /// HStack that the outer row's `alignment: .center` keeps vertically
  /// centered against the two-line identity column. The state icon's
  /// `accessibilityLabel` is the raw enum value per the user-test
  /// contract (`docs/user-tests/active-agents-view.md` §Test Surface).
  private var statusColumn: some View {
    HStack(spacing: 5) {
      stateIcon
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("activeAgents.row.\(paneID).state")
        .accessibilityLabel(entry.state.rawValue)
      Text(stateVerb)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  /// State icon glyph + color. New visual language: circle-based for
  /// every state, with a breathing opacity pulse on the two "active"
  /// states (working, waitingForInput). `.idle` uses `circle.dashed`
  /// to read as "present but quiet"; finished keeps the affirmative
  /// green check.
  @ViewBuilder
  private var stateIcon: some View {
    switch entry.state {
    case .waitingForInput:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
        .opacity(reduceMotion ? 1.0 : (pulseActive ? 0.5 : 1.0))
        .animation(
          reduceMotion
            ? nil
            : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
          value: pulseActive
        )
        .accessibilityHidden(true)
    case .loading:
      Image(systemName: "circle.fill")
        .foregroundStyle(.orange)
        .opacity(reduceMotion ? 1.0 : (pulseActive ? 0.5 : 1.0))
        .animation(
          reduceMotion
            ? nil
            : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
          value: pulseActive
        )
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

  /// Full-sentence accessibility label combining display name, project,
  /// worktree, and state. Agent name is dropped from the visible row
  /// but kept here so VoiceOver still announces which kind of agent
  /// occupies the pane.
  private var accessibilityLabelText: String {
    "\(entry.kind.displayName), \(projectName), \(worktreeName), \(sentenceVerb)"
  }
}
