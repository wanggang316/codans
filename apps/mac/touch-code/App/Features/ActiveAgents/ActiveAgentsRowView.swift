import SwiftUI
import TouchCodeCore

/// One Agent row in the ActiveAgents popover.
///
/// Layout (see `docs/design-docs/active-agents-view.md` §UI):
/// - Leading: 16pt agent logo (SF Symbol fallback `brain.head.profile` —
///   T7 swaps in real logos from `Resources/Assets.xcassets/AgentLogos/`).
/// - Center: `<ProjectName> / <WorktreeName>` with middle truncation.
/// - Trailing: state icon + state label + relative time.
///
/// Click target is the whole row — bound to `onTap`. Wiring the actual
/// focus dispatch is T6's job; T5 only exposes the closure.
///
/// Relative time refreshes itself: wrapped in a `TimelineView(.periodic)`
/// with a 30s cadence — matches the granularity of
/// `RelativeDateTimeFormatter` ("12s ago", "2m ago", "1h ago") without
/// burning redraws on per-second precision the user can't perceive.
struct ActiveAgentsRowView: View {
  let paneID: PaneID
  let entry: AgentRegistry.AgentEntry
  let projectName: String
  let worktreeName: String
  let onTap: () -> Void

  /// Formatter is shared across all rows in a popover lifetime. Building
  /// a fresh `RelativeDateTimeFormatter` per row would otherwise spin up
  /// a CFLocale + calendar + ICU context on each redraw — same pattern
  /// as `InboxRowView.relativeFormatter`.
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()

  @State private var isHovering = false
  /// `TimelineView(.periodic(from:))` rebases its schedule every time
  /// the `from:` expression re-evaluates — `Date()` inline would reset
  /// the 30s timer on every parent redraw (and the popover redraws on
  /// every `@Observable` registry mutation). Captured once at view init
  /// so the cadence is stable across redraws.
  @State private var firstTick = Date()

  var body: some View {
    // The visible age (and the matching a11y sentence) both read from
    // the same `TimelineView` clock so VoiceOver doesn't drift away
    // from what sighted users see — see the `trailing` builder.
    TimelineView(.periodic(from: firstTick, by: 30)) { context in
      let age = Self.relativeFormatter.localizedString(
        for: entry.lastTransitionAt,
        relativeTo: context.date
      )
      Button(action: onTap) {
        HStack(alignment: .center, spacing: 8) {
          logo
          headline
          Spacer(minLength: 8)
          trailing(age: age)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isHovering ? Color.gray.opacity(0.08) : Color.clear)
      }
      .buttonStyle(.plain)
      .onHover { isHovering = $0 }
      // `.contain` keeps the inner `headline` Text and `stateIcon`
      // HStack individually addressable by their sub-element
      // identifiers (user-test contract — see the type doc).
      // `.accessibilityLabel` on a `.contain` container is a no-op, so
      // the row's full-sentence VoiceOver label is installed via
      // `.accessibilityRepresentation { Button(label, action:) }` — a
      // proxy element that carries the label without collapsing the
      // children-contain semantics needed for sub-element probing.
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("activeAgents.row.\(paneID)")
      .accessibilityRepresentation {
        Button(accessibilityLabel(age: age), action: onTap)
      }
    }
  }

  /// Leading 16pt logo. v1 uses the SF Symbol fallback for every
  /// AgentKind — T7 swaps in `Image("AgentLogos/<kind.rawValue>")` once
  /// the assets ship.
  private var logo: some View {
    Image(systemName: "brain.head.profile")
      .resizable()
      .scaledToFit()
      .frame(width: 16, height: 16)
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
  }

  /// Project / Worktree breadcrumb. Middle truncation so a long worktree
  /// name doesn't push the trailing state column off-screen.
  private var headline: some View {
    Text("\(projectName) / \(worktreeName)")
      .font(.callout)
      .lineLimit(1)
      .truncationMode(.middle)
      .accessibilityIdentifier("activeAgents.row.\(paneID).headline")
  }

  /// Trailing column — state icon, state verb, relative age. The age
  /// string is computed by the surrounding `TimelineView` so the
  /// visible text and the row's a11y label share one clock. The state
  /// icon's `accessibilityLabel` is the raw enum value per the user-
  /// test contract (`docs/user-tests/active-agents-view.md` §Test
  /// Surface).
  private func trailing(age: String) -> some View {
    HStack(spacing: 6) {
      stateIcon
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("activeAgents.row.\(paneID).state")
        .accessibilityLabel(entry.state.rawValue)
      Text(stateVerb)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text("·")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(age)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// State icon glyph + color. The `.loading` case uses a SwiftUI 6
  /// symbol effect for a subtle rotation, matching the precedent in
  /// `HierarchySidebarView` (busy-pane indicator). Inner Images are
  /// `accessibilityHidden` because the wrapping view already carries
  /// the a11y label (the raw state enum value, per the user-test
  /// contract).
  @ViewBuilder
  private var stateIcon: some View {
    switch entry.state {
    case .waitingForInput:
      Image(systemName: "bell.badge.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
    case .loading:
      Image(systemName: "arrow.triangle.2.circlepath")
        .symbolEffect(.variableColor.iterative.reversing)
        .foregroundStyle(.accentColor)
        .accessibilityHidden(true)
    case .finished:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityHidden(true)
    case .idle:
      Image(systemName: "circle")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
  }

  /// Human-readable verb for the inline state label ("working" / "idle"
  /// / "waiting" / "finished"). The *accessibility* label on the state
  /// icon uses the raw enum value (the user-test contract); this text
  /// is the visible label for sighted users.
  private var stateVerb: String {
    switch entry.state {
    case .waitingForInput: return "waiting"
    case .loading: return "working"
    case .finished: return "finished"
    case .idle: return "idle"
    }
  }

  /// Full-sentence accessibility label combining display name, project /
  /// worktree breadcrumb, state, and age — the line a VoiceOver user
  /// hears when the row gains focus. `age` is supplied by the
  /// `TimelineView` clock so the spoken text stays in lockstep with
  /// the visible age (review fix I2).
  private func accessibilityLabel(age: String) -> String {
    "\(entry.kind.displayName), \(projectName) \(worktreeName), \(stateVerb), \(age)"
  }
}
