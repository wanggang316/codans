import SwiftUI

/// Compact `+N −M` line-count chip used on each Sidebar Worktree row. The
/// counts are rendered in GitHub Primer green/red (`DiffStatColor`) so the
/// chip reads like the same widget github.com shows on PRs and file lists.
/// While the row's selection chrome is emphasized (sidebar holds first
/// responder, blue fill, white text) the green/red colours fold to
/// `.secondary` so the digits stay legible against the highlight rather than
/// fighting it.
///
/// When `onTap` is non-nil the chip wraps in a Button + hairline border so it
/// reads as tappable (mirrors the chord-hint chip on the right edge of the
/// row). The tap opens the project's Git Viewer for that worktree — wiring
/// lives at the call site (`HierarchySidebarView.diffStatsChip`).
struct DiffStatsChip: View {
  let additions: Int
  let deletions: Int
  let onTap: (() -> Void)?

  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    let isEmphasized = backgroundProminence == .increased
    let additionsTint: AnyShapeStyle =
      isEmphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(DiffStatColor.additions)
    let deletionsTint: AnyShapeStyle =
      isEmphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(DiffStatColor.deletions)

    let counts = HStack(spacing: 2) {
      if additions > 0 {
        Text("+\(additions)").foregroundStyle(additionsTint)
      }
      if deletions > 0 {
        Text("−\(deletions)").foregroundStyle(deletionsTint)
      }
    }
    .font(.system(size: 10).monospacedDigit())

    let bordered =
      counts
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .overlay(
        RoundedRectangle(cornerRadius: 3)
          .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
      )

    Group {
      if let onTap {
        Button(action: onTap) { bordered }
          .buttonStyle(.plain)
          .help("Open Git Viewer")
      } else {
        counts
      }
    }
    .accessibilityLabel("\(additions) additions, \(deletions) deletions")
  }
}
