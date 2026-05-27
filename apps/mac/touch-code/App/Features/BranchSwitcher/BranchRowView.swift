import SwiftUI
import TouchCodeCore

/// One row inside the Branch popover's "Branches" section.
///
/// Pure projection of a `BranchRef`: the parent (`BranchSwitcherView`) decides
/// what the explicit action buttons do via the `onCheckout` / `onRename`
/// closures. The row body itself is no longer tappable — interaction goes
/// through hover-revealed buttons (Phase C). Blocked rows (a branch checked
/// out in another worktree of the same Project, per Phase B) render greyed
/// out, expose neither button, and surface the blocking worktree's name on
/// the trailing edge.
struct BranchRowView: View {
  let ref: BranchRef
  let isCurrent: Bool
  /// Non-nil when this branch is currently checked out by another worktree
  /// in the same Project; the value is that worktree's folder name. Local
  /// rows only — remote rows are never marked blocked.
  let blockingWorktreeName: String?
  let onCheckout: () -> Void
  let onRename: () -> Void

  @State private var isHovered = false

  private var isBlocked: Bool { blockingWorktreeName != nil }

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
        .truncationMode(.tail)
      Spacer(minLength: 8)
      trailingAccessory
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
    .contentShape(.rect)
    .background(isHovered ? Color.accentColor.opacity(0.10) : Color.clear)
    .opacity(isBlocked ? 0.55 : 1.0)
    .onHover { hovering in isHovered = hovering }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(
      "branch_switcher.branch_row.\(ref.isRemote ? "remote" : "local").\(ref.shortName)"
    )
    .accessibilityLabel(accessibilityLabel)
  }

  // MARK: - Trailing accessory

  /// Three mutually-exclusive presentations:
  ///   - Blocked: surface the blocking worktree's folder name (no button).
  ///   - Current + hovered: "Rename" button.
  ///   - Other + hovered (not blocked): "Checkout" button.
  @ViewBuilder
  private var trailingAccessory: some View {
    if let blockingName = blockingWorktreeName {
      Text("@\(blockingName)")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.tail)
        .accessibilityIdentifier("branch_switcher.branch_row.blocked_marker")
    } else if isCurrent {
      if isHovered {
        Button("Rename") { onRename() }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .font(.caption)
          .accessibilityIdentifier("branch_switcher.branch_row.rename_button")
      }
    } else {
      if isHovered {
        Button("Checkout") { onCheckout() }
          .buttonStyle(.borderless)
          .controlSize(.small)
          .font(.caption)
          .accessibilityIdentifier("branch_switcher.branch_row.checkout_button")
      }
    }
  }

  // MARK: - Accessibility label

  private var accessibilityLabel: Text {
    if let blockingName = blockingWorktreeName {
      return Text("Branch \(ref.shortName), checked out in \(blockingName)")
    }
    if isCurrent {
      return Text("Currently on \(ref.shortName)")
    }
    return Text("Switch to branch \(ref.shortName)")
  }
}

#Preview("current local") {
  BranchRowView(
    ref: BranchRef(shortName: "feat/header", isRemote: false, upstream: "origin/feat/header"),
    isCurrent: true,
    blockingWorktreeName: nil,
    onCheckout: {},
    onRename: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}

#Preview("other local") {
  BranchRowView(
    ref: BranchRef(shortName: "bugfix/menu", isRemote: false, upstream: nil),
    isCurrent: false,
    blockingWorktreeName: nil,
    onCheckout: {},
    onRename: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}

#Preview("blocked local") {
  BranchRowView(
    ref: BranchRef(shortName: "feat/x", isRemote: false, upstream: nil),
    isCurrent: false,
    blockingWorktreeName: "wt-feat-x",
    onCheckout: {},
    onRename: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}

#Preview("remote") {
  BranchRowView(
    ref: BranchRef(shortName: "origin/feat/new-shell", isRemote: true, upstream: nil),
    isCurrent: false,
    blockingWorktreeName: nil,
    onCheckout: {},
    onRename: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}
