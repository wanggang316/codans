import SwiftUI
import CodansCore

/// Compact footer mounted at the sidebar's `.safeAreaInset(edge: .bottom)`.
/// A leading help button opens the help menu (Website / Changelog, then
/// Report issue). Trailing buttons toggle the Agents View panel and open the
/// Settings window. All three share `SidebarFooterButtonStyle`. A manual
/// reconcile of every Project is the "Refresh All Projects" Command Palette
/// item. The tag-filter button, whose popover lists the tag
/// filters (`[All]`, one row per Tag, an optional `[Untagged]`, and an
/// `Edit Tags…` shortcut), is hidden.
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
  /// Trailing Settings button. nil = hide the button (previews / tests).
  var onSettingsTapped: (() -> Void)?
  /// Sidebar-relocated AgentState toggle. nil = hide the button
  /// entirely (used in previews / contexts without a registry wired).
  var onAgentStateTapped: (() -> Void)?
  /// Drives the toggle glyph (filled when open, outlined when closed)
  /// per design — no color shift, no badge dot, the glyph variant is
  /// the only ambient signal the footer carries.
  var agentStatePanelOpen: Bool = false

  var body: some View {
    HStack(spacing: 0) {
      // Tag-filter button is intentionally hidden — TagFilterList and the
      // wired callbacks stay around so the feature can be re-mounted
      // without rewiring the call site. Projects are reordered by direct
      // drag in the list (ADR 0001), so the footer has no sort control.
      SidebarHelpMenuButton()
      Spacer()
      if let onAgentStateTapped {
        Button(action: onAgentStateTapped) {
          // Glyph alone communicates open/closed via outline vs fill;
          // no state color, no badge dot — keeps the footer button
          // chrome visually quiet so the actual panel content does
          // the signalling.
          Image(
            systemName: agentStatePanelOpen
              ? "sparkles.rectangle.stack.fill"
              : "sparkles.rectangle.stack"
          )
        }
        .buttonStyle(.sidebarFooter)
        .help(agentStatePanelOpen ? "Hide agents view" : "Show agents view")
        .accessibilityLabel(
          agentStatePanelOpen ? "Hide agents view" : "Show agents view"
        )
        .accessibilityIdentifier("agentState.sidebarToggle")
      }
      if let onSettingsTapped {
        Button(action: onSettingsTapped) {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.sidebarFooter)
        .help("Settings")
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("sidebar.settingsButton")
      }
    }
    // Same insets as the Agents View card. The gap below the buttons equals
    // the one the card keeps above them, so they sit centered between the
    // card and the sidebar's bottom edge.
    .padding(.horizontal, AgentStateSidebarPanel.edgeInset)
    .padding(.bottom, AgentStateSidebarPanel.edgeInset)
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
              .accessibilityHidden(true)
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
            .accessibilityLabel("Selected")
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
