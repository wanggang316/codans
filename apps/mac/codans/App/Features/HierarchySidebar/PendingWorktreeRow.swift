import SwiftUI

/// Sidebar row for an in-flight worktree creation. Renders a spinner +
/// latest progress line while running; a red dot + truncated error
/// caption after failure. Right-click exposes Cancel (running) or
/// Retry / Discard (failed). Not natively selectable (no `.tag`); when
/// the creation is the one the detail pane is following
/// (`isHighlighted`), the container paints a manual accent background
/// and this row switches its content to the selected-row light tones.
/// See `docs/design-docs/worktree-sidebar-ordering.md` §pending 段.
struct PendingWorktreeRow: View {
  let pending: PendingWorktree
  /// True while this creation is the active one the detail pane follows —
  /// the container draws the accent selection background, so every
  /// explicitly-colored element here must flip to the light selected-row
  /// tone (the same problem `WorktreeRowIcon` solves via
  /// `backgroundProminence`, which never fires for this row because the
  /// highlight is manual, not a native List selection).
  var isHighlighted: Bool = false
  let onCancel: () -> Void
  let onRetry: () -> Void
  let onDiscard: () -> Void

  /// Reduce Motion suppresses the decorative shimmer on both lines so the
  /// in-progress state never relies on animation alone. The non-animated
  /// signals — the name's `in-progress`/`settled` accessibility value, the
  /// row's stage value, and the streaming second line — carry the state
  /// regardless. Mirrors `AgentStateRowView`'s reduce-motion gating.
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 6) {
      icon
      VStack(alignment: .leading, spacing: 0) {
        Text(pending.displayName)
          // A very long branch name truncates to a single line with a tail
          // ellipsis; the trailing `Spacer` + this lineLimit keep the row
          // from overflowing horizontally. The shimmer masks whatever text
          // remains visible after truncation.
          .lineLimit(1)
          .truncationMode(.tail)
          .foregroundStyle(primaryColor)
          // Decorative light-sweep while the creation streams; gated off on
          // failure (the row has settled) and under Reduce Motion. The
          // `nameProgressAccessibilityValue` below is the probeable signal —
          // the shimmer is purely cosmetic.
          .shimmer(isActive: pending.isRunning && !reduceMotion)
          .accessibilityValue(pending.nameProgressAccessibilityValue)
        HStack(spacing: 3) {
          // Setup-script phase glyph leads the STREAMING line, not the
          // leading icon slot: the slot keeps the animated spinner (a
          // static glyph there reads as "stalled"), while the glyph here
          // annotates WHAT is streaming. Same glyph the Settings "Setup
          // Script" lifecycle section uses.
          if pending.isRunning, pending.phase == .runningSetupScript {
            Image(systemName: "truck.box.badge.clock")
              .font(.caption2)
              .foregroundStyle(scriptGlyphColor)
              // Decorative — the stage value on the text leaf is the
              // probeable signal; the glyph only echoes it visually.
              .accessibilityHidden(true)
          }
          Text(secondaryLine)
            .font(.caption)
            .foregroundStyle(secondaryColor)
            .lineLimit(1)
            .truncationMode(.tail)
            // Stage value rides this leaf so both it and the name's
            // in-progress/settled value are probeable children under `.contain`.
            .accessibilityValue(stageAccessibilityValue)
        }
        // The second line carries the live narration; sweep it together
        // with the name so the whole row reads as one in-progress unit.
        .shimmer(isActive: pending.isRunning && !reduceMotion)
      }
      Spacer()
    }
    .contentShape(Rectangle())
    // Both values are exposed as leaf children under `.contain`:
    //   • name leaf   → `in-progress`/`settled` via `.accessibilityValue` above
    //   • status leaf → `creating`/`setupScript`/`failed` via `.accessibilityValue`
    //     on `Text(secondaryLine)` above
    // The prior approach set `.accessibilityValue` directly on the `.contain`
    // container (a no-op — silently dropped) and then used
    // `.accessibilityRepresentation` to work around that. Per Apple's docs,
    // `.accessibilityRepresentation` discards the modified subtree's
    // accessibility entirely, which risked shadowing the leaf values.
    // Leaf-based exposure is provably correct and simpler.
    .accessibilityElement(children: .contain)
    .contextMenu {
      switch pending.status {
      case .running:
        Button("Cancel", action: onCancel)
      case .failed:
        Button("Retry", action: onRetry)
        Button("Discard", role: .destructive, action: onDiscard)
      }
    }
  }

  /// Stable, machine-readable stage signal for the row, exposed as its
  /// accessibility value. The vocabulary is a fixed contract that later
  /// validation keys on — DO NOT rename these strings:
  ///   - `creating`    — running, still in the `git worktree add` leg
  ///   - `setupScript` — running, executing the project setup script
  ///   - `failed`      — creation failed (Retry / Discard offered)
  /// Complemented by the name's coarser `in-progress`/`settled` value
  /// (`PendingWorktree.nameProgressAccessibilityValue`), which the shimmer is
  /// the decorative analogue of. See `pending-phase-lifecycle`.
  private var stageAccessibilityValue: String {
    switch pending.status {
    case .failed:
      return "failed"
    case .running:
      switch pending.phase {
      case .creatingWorktree: return "creating"
      case .runningSetupScript: return "setupScript"
      }
    }
  }

  @ViewBuilder
  private var icon: some View {
    switch pending.status {
    case .running:
      // Indeterminate spinner for the WHOLE run — including the
      // setup-script leg. The script glyph annotates the second line
      // instead (see body); keeping motion in this slot is what tells
      // the user the creation is alive.
      ProgressView()
        .controlSize(.small)
        .frame(width: 14, height: 14)
        // Decorative — the status leaf's stage value is the probeable
        // signal.
        .accessibilityHidden(true)
    case .failed:
      Circle()
        .fill(Color.red)
        .frame(width: 8, height: 8)
        .frame(width: 14, height: 14)
    }
  }

  private var secondaryLine: String {
    switch pending.status {
    case .running:
      return pending.lastProgressLine ?? "Creating…"
    case .failed(let err):
      let raw = humanReadable(err)
      return raw.count > 60 ? String(raw.prefix(60)) + "…" : raw
    }
  }

  private var primaryColor: Color {
    isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : .primary
  }

  private var secondaryColor: Color {
    if isHighlighted {
      // Match the dimmed-but-light caption tone native emphasized rows
      // give their secondary text.
      return Color(nsColor: .alternateSelectedControlTextColor).opacity(0.85)
    }
    switch pending.status {
    case .running: return .secondary
    case .failed: return .red
    }
  }

  private var scriptGlyphColor: Color {
    isHighlighted
      ? Color(nsColor: .alternateSelectedControlTextColor)
      : .blue
  }
}
