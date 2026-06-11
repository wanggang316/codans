import SwiftUI
import CodansCore

/// One row inside the Branch popover's "Branches" section.
///
/// Pure projection of a `BranchRef`: the parent (`BranchSwitcherView`) decides
/// what the explicit actions do via the `onSwitch` / `onNewBranchFrom` /
/// `onRename` closures. The row body itself is no longer tappable —
/// interaction goes through a hover-revealed ellipsis Menu (Tower-style)
/// that exposes a uniform 3-item action set on every row. Blocked rows
/// (a branch checked out in another worktree of the same Project, per
/// Phase B) keep normal opacity and surface their state via a leading `+`
/// marker in the checkmark slot — no trailing `@<worktree>` label.
struct BranchRowView: View {
  let ref: BranchRef
  let isCurrent: Bool
  /// Non-nil when this branch is currently checked out by another worktree
  /// in the same Project; the value is that worktree's folder name. Local
  /// rows only — remote rows are never marked blocked. Drives ONLY the
  /// leading `+` marker; the trailing label was dropped to keep the row
  /// clean (the leading icon carries the signal on its own).
  let blockingWorktreeName: String?
  /// True when this row's branch matches the reducer's `renamingBranch`.
  /// The label collapses to a TextField bound to `renameDraft`.
  let isRenaming: Bool
  /// True while the rename effect is running. The TextField becomes
  /// non-editable until the response arrives. Cosmetic — the reducer
  /// guards re-entry separately.
  let renameInFlight: Bool
  /// Two-way binding to the reducer's `renameDraft` (composed by the
  /// parent from `store.renameDraft` + `.renameDraftChanged`).
  let renameDraft: Binding<String>
  /// Switch to (checkout) this branch. Caller disables/no-ops on the
  /// current row and on blocked rows.
  let onSwitch: () -> Void
  /// Open the "New Branch From <this>" alert. Always allowed.
  let onNewBranchFrom: () -> Void
  /// Begin inline rename. Caller disables on remote rows.
  let onRename: () -> Void
  /// Dispatched on TextField submit (Return key).
  let onRenameConfirm: () -> Void
  /// Dispatched on Escape OR when the TextField loses focus without a
  /// successful submission (e.g., user clicked outside the popover).
  let onRenameCancel: () -> Void

  @State private var isHovered = false
  @FocusState private var renameFocus: Bool

  private var isBlocked: Bool { blockingWorktreeName != nil }
  private var showsRenameField: Bool { isRenaming }

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
    // Blocked rows no longer dim — the leading `+` marker carries the
    // "checked out elsewhere" signal on its own, and the row stays
    // legible at normal contrast.
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

  /// Three mutually-exclusive presentations:
  ///   - Renaming + in-flight: small spinner (no menu).
  ///   - Renaming: no accessory — the TextField is the only affordance.
  ///   - Hovered (not renaming): uniform ellipsis Menu with `Switch` /
  ///     `New Branch From …` / `Rename…`. Blocked rows ALSO show the menu
  ///     (every branch supports the same three actions; per-item
  ///     `.disabled` handles which apply).
  @ViewBuilder
  private var trailingAccessory: some View {
    if showsRenameField {
      if renameInFlight {
        ProgressView()
          .controlSize(.mini)
          .accessibilityIdentifier("branch_switcher.rename_spinner")
      }
    } else if isHovered {
      hoverMenu
    }
  }

  /// Tower-style ellipsis dropdown that consolidates per-row actions into
  /// a single hover-revealed control. `Menu` + `.menuStyle(.borderlessButton)`
  /// + `.menuIndicator(.hidden)` renders just the ellipsis glyph with no
  /// trailing chevron — see `MergeSplitButton` for the same pattern.
  ///
  /// The same three items appear on every row; per-item `.disabled` encodes
  /// which ones apply:
  ///   - Switch:   disabled on the current row (can't switch to self).
  ///   - New Branch From: always enabled.
  ///   - Rename:   disabled on remote-tracking rows (git can't rename
  ///     them locally).
  private var hoverMenu: some View {
    Menu {
      Button("Switch", action: onSwitch)
        .disabled(isCurrent || isBlocked)
      Button("New Branch From \"\(ref.shortName)\"…", action: onNewBranchFrom)
      Button("Rename…", action: onRename)
        .disabled(ref.isRemote)
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityIdentifier("branch_switcher.branch_row.menu_button")
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
    onSwitch: {},
    onNewBranchFrom: {},
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
    onSwitch: {},
    onNewBranchFrom: {},
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
    onSwitch: {},
    onNewBranchFrom: {},
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
    onSwitch: {},
    onNewBranchFrom: {},
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
    onSwitch: {},
    onNewBranchFrom: {},
    onRename: {},
    onRenameConfirm: {},
    onRenameCancel: {}
  )
  .frame(width: 360)
  .padding(.vertical, 4)
}
