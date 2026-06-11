import SwiftUI
import CodansCore

/// Fixed-position controls on the trailing edge of the Tab bar. Lives
/// outside the scrollable chip row so these buttons stay visible
/// regardless of how many tabs are open.
///
/// Three actions: `+` creates a new tab in the active worktree; the two
/// split buttons cut a new pane horizontally or vertically off the active
/// tab's leftmost leaf.
struct TabBarTrailingAccessories: View {
  let activeTabSplitTree: SplitTree<PaneID>?
  let onNewTab: () -> Void
  let onSplitRight: () -> Void
  let onSplitDown: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      NewTabAccessoryButton(action: onNewTab)

      SplitAccessoryButton(
        systemImage: "rectangle.split.2x1",
        accessibilityLabel: "Split Right",
        chordCommandID: .splitRight,
        splitTree: activeTabSplitTree,
        action: onSplitRight
      )

      SplitAccessoryButton(
        systemImage: "rectangle.split.1x2",
        accessibilityLabel: "Split Down",
        chordCommandID: .splitDown,
        splitTree: activeTabSplitTree,
        action: onSplitDown
      )
    }
    .padding(.horizontal, 6)
  }
}

/// 22×22 circular hover affordance shared by the trailing accessories.
/// Mirrors the sidebar `iconLabel` chrome so the +/split row reads as
/// the same family of toolbar icon buttons. `TabBarColors.hoverBackground`
/// gives the standard tab-bar tint; the `Circle()` shape rounds the hit
/// target without changing the underlying button hit detection.
private struct AccessoryIconChrome: ViewModifier {
  let isHovering: Bool

  func body(content: Content) -> some View {
    content
      .frame(width: 22, height: 22)
      .background(
        Circle()
          .fill(isHovering ? TabBarColors.hoverBackground : .clear)
      )
      .contentShape(Circle())
  }
}

/// `+` button. Split into its own view so the hover state is local and
/// doesn't redraw siblings on every pointer crossing.
private struct NewTabAccessoryButton: View {
  let action: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .accessibilityLabel("New Tab")
        .modifier(AccessoryIconChrome(isHovering: isHovering))
        .commandKeyHint(.newTab)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .helpWithShortcut("New Tab", .newTab)
  }
}

/// Trailing split button. Mirrors a registry chord (`.splitRight` /
/// `.splitDown`) so the chord glyph appears inline while ⌘ is held and
/// the tooltip resolves the same binding.
private struct SplitAccessoryButton: View {
  let systemImage: String
  let accessibilityLabel: String
  let chordCommandID: CommandID
  let splitTree: SplitTree<PaneID>?
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .accessibilityLabel(accessibilityLabel)
        .modifier(AccessoryIconChrome(isHovering: isHovering))
        .commandKeyHint(chordCommandID)
    }
    .buttonStyle(.plain)
    .disabled(splitTree?.root == nil)
    .onHover { isHovering = $0 }
    .helpWithShortcut(accessibilityLabel, chordCommandID)
  }
}
