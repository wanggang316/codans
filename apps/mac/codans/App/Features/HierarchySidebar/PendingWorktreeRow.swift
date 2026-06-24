import SwiftUI

/// Sidebar row for an in-flight worktree creation. Renders a spinner +
/// latest progress line while running; a red dot + truncated error
/// caption after failure. Right-click exposes Cancel (running) or
/// Retry / Discard (failed). Not selectable; not eligible for ⌃⌘N.
/// See `docs/design-docs/worktree-sidebar-ordering.md` §pending 段.
struct PendingWorktreeRow: View {
  let pending: PendingWorktree
  let onCancel: () -> Void
  let onRetry: () -> Void
  let onDiscard: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      icon
      VStack(alignment: .leading, spacing: 0) {
        Text(pending.displayName)
          .lineLimit(1)
        Text(secondaryLine)
          .font(.caption)
          .foregroundStyle(secondaryColor)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer()
    }
    .contentShape(Rectangle())
    // Keep the child Text nodes (display name + streaming second line)
    // readable to accessibility while still attaching the stable stage
    // value below — `.contain` merges children under this element.
    .accessibilityElement(children: .contain)
    .accessibilityValue(stageAccessibilityValue)
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
  /// See `pending-phase-lifecycle`.
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
      ProgressView()
        .controlSize(.small)
        .frame(width: 14, height: 14)
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

  private var secondaryColor: Color {
    switch pending.status {
    case .running: return .secondary
    case .failed: return .red
    }
  }
}
