import SwiftUI
import CodansCore

/// Compact footer mounted at the sidebar's `.safeAreaInset(edge: .bottom)`.
/// Two glyphs anchored at opposite edges: a leading tag-filter button whose
/// popover lists the available tag filters (`[All]`, one row per Tag, an
/// optional `[Untagged]`, and an `Edit Tags…` shortcut), and a trailing
/// refresh button that re-runs the project reconciler manually so the user
/// can pick up out-of-band changes (e.g. a folder that just got `git init`)
/// without waiting for the focus-driven cadence.
///
/// The filter icon flips to its `.fill` variant tinted with
/// `Color.accentColor` whenever the active filter is anything other than
/// `.all`, so the user can tell at a glance that the project list is being
/// filtered without opening the popover.
struct TagFilterPopoverFooter: View {
  let tags: [Tag]
  let activeFilter: TagFilter
  let showUntaggedChip: Bool
  let onAllTapped: () -> Void
  let onTagTapped: (TagID) -> Void
  let onUntaggedTapped: () -> Void
  /// Trailing "Edit Tags…" entry — opens the TagManager sheet.
  /// Optional so previews / tests without manager wiring can omit it.
  var onEditTagsTapped: (() -> Void)?
  /// Right-side refresh glyph. Optional so previews / tests without a
  /// reconciler wired can drop it.
  var onRefreshTapped: (() -> Void)?
  /// Project-sort popover wiring. When nil, the sort button is hidden —
  /// preserves the existing footer shape in previews / tests that don't
  /// thread sort state through.
  var sortMode: ProjectSortMode?
  var onSortModeChanged: ((ProjectSortMode) -> Void)?
  var onManualSortRequested: (() -> Void)?
  /// Sidebar-relocated AgentState toggle. nil = hide the button
  /// entirely (used in previews / contexts without a registry wired).
  var onAgentStateTapped: (() -> Void)?
  /// Drives the toggle glyph (filled when open, outlined when closed)
  /// per design — no color shift, no badge dot, the glyph variant is
  /// the only ambient signal the footer carries.
  var agentStatePanelOpen: Bool = false

  @State private var isSortPopoverPresented = false

  var body: some View {
    HStack(spacing: 0) {
      // Tag-filter button is intentionally hidden — TagFilterList and the
      // wired callbacks stay around so the feature can be re-mounted
      // without rewiring the call site, but the footer currently only
      // surfaces sort + refresh.
      HStack(spacing: 6) {
        if let sortMode, let onSortModeChanged, let onManualSortRequested {
          Button {
            isSortPopoverPresented.toggle()
          } label: {
            // The sort glyph stays visually neutral regardless of the
            // active mode — unlike the tag filter, "sort order" is a
            // navigation aid rather than a constraint hiding rows, so
            // there is nothing to draw the eye to once the user has
            // made their choice.
            Image(systemName: "arrow.up.arrow.down")
              .font(.system(size: 11, weight: .regular))
              .foregroundStyle(.secondary)
              .frame(width: 18, height: 18)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(sortHelpText(for: sortMode))
          .accessibilityLabel("Sort projects")
          .popover(isPresented: $isSortPopoverPresented, arrowEdge: .bottom) {
            ProjectSortList(
              mode: sortMode,
              onSelect: { picked in
                // Dismiss the popover first so the user sees the
                // re-sorted list as soon as the callback runs —
                // leaving it open swallows the visual feedback they
                // expect.
                isSortPopoverPresented = false
                if picked == .manual {
                  onManualSortRequested()
                } else {
                  onSortModeChanged(picked)
                }
              }
            )
          }
        }
      }
      Spacer()
      if let onAgentStateTapped {
        Button(action: onAgentStateTapped) {
          // Glyph alone communicates open/closed via outline vs fill;
          // no color shift, no badge dot — keeps the footer button
          // chrome visually quiet so the actual panel content does
          // the signalling.
          Image(
            systemName: agentStatePanelOpen
              ? "sparkles.rectangle.stack.fill"
              : "sparkles.rectangle.stack"
          )
          .font(.system(size: 13, weight: .regular))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(agentStatePanelOpen ? "Hide agents view" : "Show agents view")
        .accessibilityLabel(
          agentStatePanelOpen ? "Hide agents view" : "Show agents view"
        )
        .accessibilityIdentifier("agentState.sidebarToggle")
      }
      if let onRefreshTapped {
        Button(action: onRefreshTapped) {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Refresh all projects")
        .accessibilityLabel("Refresh all projects")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
  }

  private func sortHelpText(for mode: ProjectSortMode) -> String {
    switch mode {
    case .joinOrder: return "Sort projects"
    case .activeFirst: return "Sorted by recent activity — click to change"
    case .manual: return "Sorted manually — click to change"
    }
  }
}

/// Three-row vertical list shown inside the sort popover. Visually
/// mirrors `TagFilterList` so the two bottom-bar popovers share the
/// same row chrome.
private struct ProjectSortList: View {
  let mode: ProjectSortMode
  let onSelect: (ProjectSortMode) -> Void

  @State private var hoveredMode: ProjectSortMode?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      row(.joinOrder, label: "By Date Added")
      Divider().padding(.vertical, 2)
      row(.activeFirst, label: "Recently Active")
      Divider().padding(.vertical, 2)
      row(.manual, label: "Manual Order…")
    }
    .padding(6)
    .frame(minWidth: 200)
  }

  @ViewBuilder
  private func row(_ value: ProjectSortMode, label: String) -> some View {
    let isSelected = value == mode
    let isHovered = hoveredMode == value
    Button {
      onSelect(value)
    } label: {
      HStack(spacing: 8) {
        Color.clear.frame(width: 10, height: 10)
        Text(label)
          .font(.callout)
          .foregroundStyle(isSelected ? Color.white : .primary)
          .lineLimit(1)
        Spacer(minLength: 8)
        if isSelected {
          Image(systemName: "checkmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.white)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      hoveredMode = hovering ? value : (hoveredMode == value ? nil : hoveredMode)
    }
  }
}

/// Shared row background used by the bottom-bar popover lists. Mirrors
/// native NSMenu item chrome: a 4-pt rounded fill that's clear by
/// default, gets a light hover tint, and flips to the full accent color
/// (with white foreground) when the row is the current selection.
@ViewBuilder
private func rowBackground(isSelected: Bool, isHovered: Bool) -> some View {
  RoundedRectangle(cornerRadius: 4, style: .continuous)
    .fill(
      isSelected
        ? AnyShapeStyle(Color.accentColor)
        : (isHovered ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(Color.clear))
    )
}

/// Vertical list of filter rows shown inside the footer's popover. Each
/// row is a tappable `Button` styled with a leading colored dot (when the
/// row corresponds to a Tag), the row label, and a trailing checkmark when
/// the row is part of the active filter. `[All]` and `[Untagged]` rows
/// have no dot. The popover does NOT auto-dismiss on tap so the user can
/// toggle multiple tags in one pass; `[All]` still clears the filter
/// because the reducer treats it as a hard reset.
private struct TagFilterList: View {
  let tags: [Tag]
  let activeFilter: TagFilter
  let showUntaggedChip: Bool
  let onAllTapped: () -> Void
  let onTagTapped: (TagID) -> Void
  let onUntaggedTapped: () -> Void
  var onEditTagsTapped: (() -> Void)?

  /// Identifier of the row currently under the cursor. Strings are used
  /// instead of a typed enum so the "All", per-tag, "Untagged" and "Edit"
  /// rows can share a single hover-tracking state.
  @State private var hoveredRowID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      filterRow(
        id: "all",
        label: "All",
        color: nil,
        isSelected: isAllSelected,
        action: onAllTapped
      )
      if !tags.isEmpty {
        Divider().padding(.vertical, 2)
        ForEach(tags) { tag in
          filterRow(
            id: "tag-\(tag.id.raw.uuidString)",
            label: tag.name,
            color: tag.color,
            isSelected: isTagSelected(tag.id),
            action: { onTagTapped(tag.id) }
          )
        }
      }
      if showUntaggedChip {
        Divider().padding(.vertical, 2)
        filterRow(
          id: "untagged",
          label: "Untagged",
          color: nil,
          isSelected: isUntaggedSelected,
          action: onUntaggedTapped
        )
      }
      if let onEditTagsTapped {
        Divider().padding(.vertical, 2)
        let editID = "edit"
        let isHovered = hoveredRowID == editID
        Button(action: onEditTagsTapped) {
          HStack(spacing: 8) {
            Image(systemName: "pencil")
              .font(.system(size: 11))
              .frame(width: 12)
              .foregroundStyle(isHovered ? Color.primary : .secondary)
            Text("Edit Tags…")
              .font(.callout)
              .foregroundStyle(.primary)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(rowBackground(isSelected: false, isHovered: isHovered))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
          hoveredRowID = hovering ? editID : (hoveredRowID == editID ? nil : hoveredRowID)
        }
      }
    }
    .padding(6)
    .frame(minWidth: 200)
  }

  @ViewBuilder
  private func filterRow(
    id: String,
    label: String,
    color: TagColor?,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    let isHovered = hoveredRowID == id
    Button(action: action) {
      HStack(spacing: 8) {
        if let color {
          Circle()
            .fill(swiftUIColor(for: color))
            .frame(width: 10, height: 10)
        } else {
          Color.clear.frame(width: 10, height: 10)
        }
        Text(label)
          .font(.callout)
          .foregroundStyle(isSelected ? Color.white : .primary)
          .lineLimit(1)
        Spacer(minLength: 8)
        if isSelected {
          Image(systemName: "checkmark")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.white)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      hoveredRowID = hovering ? id : (hoveredRowID == id ? nil : hoveredRowID)
    }
  }

  private var isAllSelected: Bool {
    if case .all = activeFilter { return true }
    if case .tags(let set) = activeFilter, set.isEmpty { return true }
    return false
  }

  private var isUntaggedSelected: Bool {
    if case .untagged = activeFilter { return true }
    return false
  }

  private func isTagSelected(_ id: TagID) -> Bool {
    if case .tags(let set) = activeFilter { return set.contains(id) }
    return false
  }
}

/// Maps the fixed Finder palette onto `SwiftUI.Color`. Kept inside the
/// view (not on `TagColor` itself) so the core type stays UI-framework
/// neutral.
func swiftUIColor(for color: TagColor) -> Color {
  switch color {
  case .red: return .red
  case .orange: return .orange
  case .yellow: return .yellow
  case .green: return .green
  case .blue: return .blue
  case .purple: return .purple
  case .grey: return .gray
  }
}
