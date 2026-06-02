import SwiftUI

/// Compact `+N −M` line-count chip used on each Sidebar Worktree row. The
/// counts are rendered in GitHub Primer green/red (`DiffStatColor`) so the
/// chip reads like the same widget github.com shows on PRs and file lists.
/// While the row's selection chrome is emphasized (sidebar holds first
/// responder, blue fill, white text) the green/red colours fold to
/// `.secondary` so the digits stay legible against the highlight rather than
/// fighting it.
struct DiffStatsChip: View {
  let additions: Int
  let deletions: Int

  @Environment(\.backgroundProminence) private var backgroundProminence

  var body: some View {
    let isEmphasized = backgroundProminence == .increased
    let additionsTint: AnyShapeStyle =
      isEmphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(DiffStatColor.additions)
    let deletionsTint: AnyShapeStyle =
      isEmphasized ? AnyShapeStyle(.secondary) : AnyShapeStyle(DiffStatColor.deletions)

    HStack(spacing: 2) {
      if additions > 0 {
        Text("+\(additions)").foregroundStyle(additionsTint)
      }
      if deletions > 0 {
        Text("−\(deletions)").foregroundStyle(deletionsTint)
      }
    }
    .font(.system(size: 10).monospacedDigit())
    .accessibilityLabel("\(additions) additions, \(deletions) deletions")
  }
}
