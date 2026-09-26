import CodansCore
import SwiftUI

/// One tab chip. Composes label + close button on top of a state-aware
/// background and owns the chip's local hover / press state. The chip
/// accepts plain closures rather than a TCA store so it stays agnostic
/// of the feature that drives it — future milestones bolt drag /
/// middle-click affordances onto the same shape without widening that
/// dependency.
///
/// Rename UX lives outside the chip: the context menu's Rename action
/// fires `onRenameRequested`, and the parent (`TabBarView`) presents
/// the editor as a window-attached sheet via `.sheet(item:)`. Keeping
/// the editor at the bar level avoids per-chip popover state and gives
/// rename a proper modal surface.
struct TabChipView: View {
  let title: String
  let isActive: Bool
  let isDirty: Bool
  let isOnlyTab: Bool
  let isLastTab: Bool
  /// L2 unread dot — set when this Tab's id appears in
  /// `RollupIndexProvider.current.unreadTabs`.
  let hasUnreadNotification: Bool
  /// Pre-resolved chord text to display in the chip's trailing slot while ⌘ is held —
  /// e.g. `"⌘1"` for the first chip, `"⌘0"` for the tenth, `nil` for the rest. The chord
  /// temporarily takes the close-button slot so the hint sits inside the chip's rounded
  /// rectangle rather than crowding the inter-chip gap. Resolved at the row level so
  /// `TabChipView` stays free of environment-key dependencies.
  var chordHint: String? = nil
  let onSelect: () -> Void
  let onClose: () -> Void
  let onMiddleClick: () -> Void
  let onCloseOthers: () -> Void
  let onCloseToRight: () -> Void
  let onCloseAll: () -> Void
  let onRenameRequested: () -> Void
  let onChangeColor: () -> Void
  let onChangeIcon: () -> Void
  let onCopyID: () -> Void
  let tabColor: TabColor?
  /// SF Symbol resolved by `Tab.resolvedIcon(autoFallback:)` — `nil`
  /// hides the leading slot so unlocked tabs without a runtime fallback
  /// keep the chip clean.
  var icon: String? = nil
  /// Script-tint colour for `icon` while the tab's run pane executes; see
  /// `TabChipLabel.iconTint`.
  var iconTint: Color?
  /// Overflow stacking (`TabStackLayout`): the visible width of this chip
  /// when it is compressed into a stack sliver. The chip still lays its
  /// content out at full chip width — as the system bar does — shifts it by
  /// `contentShift`, and clips it to the sliver. `nil` = not compressed.
  var sliceWidth: CGFloat?
  var contentShift: CGFloat = 0
  /// A click on a stack sliver scrolls the row instead of selecting the
  /// tab. `nil` for chips that are not part of a stack.
  var onStackClick: (() -> Void)?

  @State private var isHovering = false

  var body: some View {
    Group {
      if let sliceWidth {
        chipContent
          // A sliver is not a click target of its own: the select button
          // fires on mouse-down and would win over the stack click.
          .allowsHitTesting(onStackClick == nil)
          .offset(x: contentShift)
          .frame(width: TabStackLayout.chipWidth, alignment: .leading)
          .mask(alignment: .leading) { Rectangle().frame(width: sliceWidth) }
          .background(alignment: .leading) { background.frame(width: sliceWidth) }
          .overlay(alignment: .leading) {
            if let onStackClick {
              Color.clear
                .frame(width: sliceWidth)
                .contentShape(Rectangle())
                .onTapGesture(perform: onStackClick)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Show Stacked Tabs")
            }
          }
      } else {
        chipContent.background(background)
      }
    }
    .overlay(TabChipMiddleClickView(onMiddleClick: onMiddleClick))
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.10)) {
        isHovering = hovering
      }
    }
    .contextMenu {
      TabChipContextMenu(
        isOnlyTab: isOnlyTab,
        isLastTab: isLastTab,
        onRename: onRenameRequested,
        onChangeColor: onChangeColor,
        onChangeIcon: onChangeIcon,
        onCopyID: onCopyID,
        onClose: onClose,
        onCloseOthers: onCloseOthers,
        onCloseToRight: onCloseToRight,
        onCloseAll: onCloseAll
      )
    }
  }

  private var background: some View {
    TabChipBackground(isActive: isActive, isHovering: isHovering)
  }

  private var chipContent: some View {
    // Hit layout: the select Button claims the whole chip rectangle so
    // a click anywhere on the chip selects it; the close button (leading)
    // and the color dot / chord hint (trailing) are overlays on the same
    // rectangle so the close button intercepts its own taps without
    // forwarding to the outer Button. Without this, an HStack-of-Button-
    // plus-sibling layout leaves dead zones that swallow clicks.
    //
    // Width is owned by the row (`TabBarRowView` splits the track equally),
    // so the chip only fills whatever it is given.
    // Selection happens on mouse-down (see `SelectOnPressStyle`), like the
    // system tab bar. The Button action only fires for a chip that is still
    // unselected on release — i.e. an accessibility / keyboard press — so a
    // mouse click never dispatches select twice.
    Button(action: selectIfInactive) {
      TabChipLabel(
        title: title,
        isActive: isActive,
        isDirty: isDirty,
        hasUnreadNotification: hasUnreadNotification,
        icon: icon,
        iconTint: iconTint
      )
      // `maxHeight: .infinity` is the load-bearing piece — without
      // it the label collapses to its intrinsic text height (~16pt)
      // and the Button's hit region only covers that strip,
      // leaving most of the chip dead. Pair with the explicit
      // `contentShape` here so the styled Button uses the expanded
      // rectangle as its hit shape, not the text glyph bounds.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      // Reserve the side slots symmetrically so the centered title stays
      // centered and truncates before it slides under either overlay.
      .padding(.horizontal, TabBarMetrics.chipTitleInset)
    }
    .buttonStyle(SelectOnPressStyle(onPress: selectIfInactive))
    .frame(maxWidth: .infinity, minHeight: TabBarMetrics.chipHeight, maxHeight: TabBarMetrics.chipHeight)
    .overlay(alignment: .leading) {
      TabChipCloseButton(isVisible: isHovering, action: onClose)
        .padding(.leading, TabBarMetrics.chipSlotInset)
    }
    .overlay(alignment: .trailing) {
      // Chord hint takes the trailing slot while ⌘ is held; otherwise the
      // tab's color dot (when set) sits there.
      Group {
        if let chordHint {
          Text(chordHint)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        } else if let tabColor {
          Circle()
            .fill(tabColor.swiftUIColor)
            .frame(width: 8, height: 8)
            .frame(width: TabBarMetrics.closeButtonSize)
        }
      }
      .padding(.trailing, TabBarMetrics.chipSlotInset)
      .allowsHitTesting(false)
    }
  }

  private func selectIfInactive() {
    if !isActive { onSelect() }
  }
}

/// Button style that selects the chip as soon as the mouse goes down,
/// matching the system tab bar, without capturing pointer events away from
/// the surrounding hover handler or the reorder drag gesture.
private struct SelectOnPressStyle: ButtonStyle {
  let onPress: () -> Void

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .onChange(of: configuration.isPressed) { _, isPressed in
        if isPressed { onPress() }
      }
  }
}
