import SwiftUI
import TouchCodeCore

/// One row inside the Branch popover's "Branches" section.
///
/// Pure projection of a `BranchRef`: the parent (`BranchSwitcherView`) decides
/// what the explicit actions do via the `onCheckout` / `onRename` closures.
/// The row body itself is no longer tappable — interaction goes through a
/// hover-revealed ellipsis Menu (Tower-style). Blocked rows (a branch
/// checked out in another worktree of the same Project, per Phase B) keep
/// normal opacity, expose no menu, and surface the blocking worktree's
/// name on the trailing edge along with a leading `+` marker in the
/// checkmark slot.
struct BranchRowView: View {
  let ref: BranchRef
  let isCurrent: Bool
  /// Non-nil when this branch is currently checked out by another worktree
  /// in the same Project; the value is that worktree's folder name. Local
  /// rows only — remote rows are never marked blocked.
  let blockingWorktreeName: String?
  /// True when this row is the current branch AND user clicked Rename.
  /// The label collapses to a TextField bound to `renameDraft`.
  let isRenaming: Bool
  /// True while the rename effect is running. The TextField becomes
  /// non-editable until the response arrives. Cosmetic — the reducer
  /// guards re-entry separately.
  let renameInFlight: Bool
  /// Two-way binding to the reducer's `renameDraft` (composed by the
  /// parent from `store.renameDraft` + `.renameDraftChanged`).
  let renameDraft: Binding<String>
  let onCheckout: () -> Void
  let onRename: () -> Void
  /// Dispatched on TextField submit (Return key).
  let onRenameConfirm: () -> Void
  /// Dispatched on Escape OR when the TextField loses focus without a
  /// successful submission (e.g., user clicked outside the popover).
  let onRenameCancel: () -> Void

  @State private var isHovered = false
  @FocusState private var renameFocus: Bool

  private var isBlocked: Bool { blockingWorktreeName != nil }
  private var showsRenameField: Bool { isCurrent && isRenaming }

  var body: some View {
    HStack(spacing: 6) {
      // Reserve the leading column for every row so the branch-name
      // baseline stays aligned regardless of which marker (if any) shows.
      // Three mutually-exclusive states share the slot:
      //   - current:  checkmark
      //   - blocked:  `+` (signal: another worktree has this branch; the
      //     user could create a new worktree if they wanted to)
      //   - other:    empty (Color.clear placeholder)
      // An empty SF Symbol name logs a runtime warning, so Color.clear is
      // the spacer for the empty case.
      Group {
        if isCurrent {
          Image(systemName: "checkmark")
            .font(.caption)
            .foregroundStyle(.primary)
            .accessibilityIdentifier("branch_switcher.current_marker")
            .accessibilityHidden(true)
        } else if isBlocked {
          Image(systemName: "plus")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .accessibilityIdentifier("branch_switcher.branch_row.blocked_marker")
            .accessibilityHidden(true)
        } else {
          Color.clear
        }
      }
      .frame(width: 12)
      if showsRenameField {
        renameField
      } else {
        Text(ref.shortName)
          .font(.body)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 8)
      trailingAccessory
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
    .contentShape(.rect)
    .background(isHovered ? Color.accentColor.opacity(0.10) : Color.clear)
    // Blocked rows no longer dim — the leading `+` marker and trailing
    // `@<worktree>` label carry the "checked out elsewhere" signal on
    // their own, and the row stays legible at normal contrast.
    .onHover { hovering in isHovered = hovering }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(
      "branch_switcher.branch_row.\(ref.isRemote ? "remote" : "local").\(ref.shortName)"
    )
    .accessibilityLabel(accessibilityLabel)
  }

  // MARK: - Rename field

  /// Inline TextField that replaces the branch label while `isRenaming` is
  /// true. Auto-focused on appear so the user can type immediately;
  /// Return submits, Esc cancels via `onExitCommand`.
  private var renameField: some View {
    TextField("", text: renameDraft, onCommit: onRenameConfirm)
      .textFieldStyle(.plain)
      .font(.body)
      .focused($renameFocus)
      .onAppear { renameFocus = true }
      .onExitCommand(perform: onRenameCancel)
      .disabled(renameInFlight)
      .accessibilityIdentifier("branch_switcher.rename_field")
  }

  // MARK: - Trailing accessory

  /// Four mutually-exclusive presentations:
  ///   - Renaming + in-flight: small spinner (no menu).
  ///   - Renaming: no accessory — the TextField is the only affordance.
  ///   - Blocked: surface the blocking worktree's folder name (no menu).
  ///   - Hovered (not blocked, not renaming): ellipsis Menu with context
  ///     items — `Rename…` on the current row, `Checkout` on other rows.
  @ViewBuilder
  private var trailingAccessory: some View {
    if showsRenameField {
      if renameInFlight {
        ProgressView()
          .controlSize(.mini)
          .accessibilityIdentifier("branch_switcher.rename_spinner")
      }
    } else if let blockingName = blockingWorktreeName {
      // Plain Text — the `+` marker in the leading slot carries the
      // accessibility identifier for the blocked state. The trailing
      // label is just supplementary context.
      Text("@\(blockingName)")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.tail)
    } else if isHovered {
      hoverMenu
    }
  }

  /// Tower-style ellipsis dropdown that consolidates per-row actions into
  /// a single hover-revealed control. `Menu` + `.menuStyle(.borderlessButton)`
  /// + `.menuIndicator(.hidden)` renders just the ellipsis glyph with no
  /// trailing chevron — see `MergeSplitButton` for the same pattern.
  private var hoverMenu: some View {
    Menu {
      if isCurrent {
        Button("Rename…", action: onRename)
      } else {
        Button("Checkout", action: onCheckout)
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityIdentifier(
      isCurrent
        ? "branch_switcher.branch_row.menu_button.current"
        : "branch_switcher.branch_row.menu_button.checkout"
    )
    .accessibilityLabel("Branch actions")
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
    isRenaming: false,
    renameInFlight: false,
    renameDraft: .constant(""),
    onCheckout: {},
    onRename: {},
    onRenameConfirm: {},
    onRenameCancel: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}

#Preview("current local renaming") {
  BranchRowView(
    ref: BranchRef(shortName: "feat/header", isRemote: false, upstream: "origin/feat/header"),
    isCurrent: true,
    blockingWorktreeName: nil,
    isRenaming: true,
    renameInFlight: false,
    renameDraft: .constant("feat/header"),
    onCheckout: {},
    onRename: {},
    onRenameConfirm: {},
    onRenameCancel: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}

#Preview("other local") {
  BranchRowView(
    ref: BranchRef(shortName: "bugfix/menu", isRemote: false, upstream: nil),
    isCurrent: false,
    blockingWorktreeName: nil,
    isRenaming: false,
    renameInFlight: false,
    renameDraft: .constant(""),
    onCheckout: {},
    onRename: {},
    onRenameConfirm: {},
    onRenameCancel: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}

#Preview("blocked local") {
  BranchRowView(
    ref: BranchRef(shortName: "feat/x", isRemote: false, upstream: nil),
    isCurrent: false,
    blockingWorktreeName: "wt-feat-x",
    isRenaming: false,
    renameInFlight: false,
    renameDraft: .constant(""),
    onCheckout: {},
    onRename: {},
    onRenameConfirm: {},
    onRenameCancel: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}

#Preview("remote") {
  BranchRowView(
    ref: BranchRef(shortName: "origin/feat/new-shell", isRemote: true, upstream: nil),
    isCurrent: false,
    blockingWorktreeName: nil,
    isRenaming: false,
    renameInFlight: false,
    renameDraft: .constant(""),
    onCheckout: {},
    onRename: {},
    onRenameConfirm: {},
    onRenameCancel: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}
