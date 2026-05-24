import SwiftUI
import TouchCodeCore

/// One row inside the Branch popover's "Branches" section.
///
/// Pure projection of a `BranchRef`: the parent (`BranchSwitcherView`) decides
/// whether tapping this row should do anything by passing a real or a no-op
/// `onTap` closure — the current branch is rendered tappable but inert so the
/// view itself stays dumb.
struct BranchRowView: View {
  let ref: BranchRef
  let isCurrent: Bool
  let onTap: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 6) {
      // Reserve the checkmark column for non-current rows too so every row
      // aligns at the branch-name baseline regardless of selection. An
      // empty SF Symbol name logs a runtime warning, so use Color.clear as
      // the spacer when the row is not current.
      Group {
        if isCurrent {
          Image(systemName: "checkmark")
            .font(.caption)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("branch_switcher.current_marker")
            .accessibilityHidden(true)
        } else {
          Color.clear
        }
      }
      .frame(width: 12)
      Text(ref.shortName)
        .font(.body)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      if ref.isRemote {
        Text("remote")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
    .contentShape(.rect)
    .background(isHovered ? Color.accentColor.opacity(0.10) : Color.clear)
    .onHover { hovering in isHovered = hovering }
    .onTapGesture(perform: onTap)
    .accessibilityIdentifier(
      "branch_switcher.branch_row.\(ref.isRemote ? "remote" : "local").\(ref.shortName)"
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      isCurrent
        ? "Currently on \(ref.shortName)"
        : "Switch to branch \(ref.shortName)"
    )
    .accessibilityAddTraits(.isButton)
  }
}

#Preview("current local") {
  BranchRowView(
    ref: BranchRef(shortName: "feat/header", isRemote: false, upstream: "origin/feat/header"),
    isCurrent: true,
    onTap: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}

#Preview("other local") {
  BranchRowView(
    ref: BranchRef(shortName: "bugfix/menu", isRemote: false, upstream: nil),
    isCurrent: false,
    onTap: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}

#Preview("remote") {
  BranchRowView(
    ref: BranchRef(shortName: "origin/feat/new-shell", isRemote: true, upstream: nil),
    isCurrent: false,
    onTap: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}
