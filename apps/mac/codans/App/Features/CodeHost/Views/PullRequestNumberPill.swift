import SwiftUI
import CodansCore

/// The `#N` PR-number pill shared by the sidebar `PullRequestBadge` and the titlebar
/// `StatusPullRequestView`. Extracted so the two surfaces render the number identically
/// — bordered capsule, state-tinted digits — and never drift apart. The corner radius
/// matches both call sites so the pill reads as one component regardless of host.
///
/// Merge-conflict styling lives here so it is applied uniformly: when the head branch no
/// longer merges cleanly the digits and the border both turn red and a leading warning
/// triangle is prepended. Non-conflicted PRs tint by lifecycle state (green open / grey
/// draft / purple merged / red closed) via `rowTint`.
struct PullRequestNumberPill: View {
  let snapshot: PullRequestSnapshot

  var body: some View {
    let hasConflict = snapshot.hasMergeConflict
    // Conflict overrides the lifecycle tint: a red `#N` is the dominant signal because a
    // conflicted PR can't merge regardless of whether it's open / draft.
    let tint = hasConflict ? Color.red : snapshot.state.rowTint(isDraft: snapshot.isDraft)
    HStack(spacing: 2) {
      if hasConflict {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 8))
          .foregroundStyle(.red)
          .accessibilityHidden(true)
      }
      Text("#\(snapshot.number)")
        .font(.system(size: 10, weight: .semibold).monospacedDigit())
        .foregroundStyle(tint)
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 1)
    .background(
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .stroke(tint.opacity(0.75), lineWidth: 0.75)
    )
  }
}
