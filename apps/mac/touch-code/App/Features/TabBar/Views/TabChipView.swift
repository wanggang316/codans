import SwiftUI
import TouchCodeCore

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

  @State private var isHovering = false
  @State private var isPressing = false

  var body: some View {
    // Hit layout: the select Button claims the whole chip rectangle so
    // a click anywhere on the chip selects it; the close button is
    // overlaid on the trailing edge inside the same ZStack so it
    // intercepts its own taps without forwarding to the outer Button.
    // Without this, an HStack-of-Button-plus-sibling layout leaves dead
    // zones (between the label and the close glyph, and on either
    // chip-padding strip) that swallow clicks.
    ZStack(alignment: .trailing) {
      Button(action: onSelect) {
        TabChipLabel(
          title: title,
          isActive: isActive,
          isDirty: isDirty,
          hasUnreadNotification: hasUnreadNotification,
          icon: icon
        )
        // `maxHeight: .infinity` is the load-bearing piece — without
        // it the label collapses to its intrinsic text height (~16pt)
        // and the Button's hit region only covers that strip,
        // leaving most of the chip dead. Pair with the explicit
        // `contentShape` here so the styled Button uses the expanded
        // rectangle as its hit shape, not the text glyph bounds.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.horizontal, TabBarMetrics.chipHorizontalPadding)
        // Reserve space for the close glyph + its gap so long titles
        // truncate before they slide under the overlay.
        .padding(.trailing, TabBarMetrics.closeButtonSize + 4)
      }
      .buttonStyle(ChipPressTrackingStyle(isPressing: $isPressing))
      .frame(
        minWidth: TabBarMetrics.chipMinWidth,
        maxWidth: TabBarMetrics.chipMaxWidth,
        minHeight: TabBarMetrics.chipHeight,
        maxHeight: TabBarMetrics.chipHeight
      )

      // Trailing slot: chord hint takes precedence while ⌘ is held;
      // otherwise the color dot (when set) occupies the close-button slot —
      // hover/active reveals the close button on top, hiding the dot.
      if let chordHint {
        Text(chordHint)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .padding(.trailing, TabBarMetrics.chipHorizontalPadding)
          .accessibilityHidden(true)
          .allowsHitTesting(false)
      } else {
        ZStack {
          if let tabColor {
            Circle()
              .fill(tabColor.swiftUIColor)
              .frame(width: 8, height: 8)
              .opacity(isHovering ? 0 : 1)
              .allowsHitTesting(false)
          }
          TabChipCloseButton(
            isVisible: isHovering,
            action: onClose
          )
        }
        .padding(.trailing, TabBarMetrics.chipHorizontalPadding)
      }
    }
    .background(
      TabChipBackground(
        isActive: isActive,
        isHovering: isHovering,
        isPressing: isPressing
      )
    )
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
}

/// Button style that exposes `isPressed` as a binding so the chip can
/// recolor its background during a tap without capturing pointer events
/// away from the surrounding hover handler.
private struct ChipPressTrackingStyle: ButtonStyle {
  @Binding var isPressing: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .onChange(of: configuration.isPressed) { _, newValue in
        isPressing = newValue
      }
  }
}
