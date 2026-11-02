import SwiftUI
import CodansCore

/// Right-click context menu for a tab chip. Built as a `@ViewBuilder` so
/// `TabChipView` can attach it with `.contextMenu { TabChipContextMenu(…) }`
/// without a ViewModifier round-trip. The items reflect the plan's menu
/// surface: Copy Tab ID, Close, Close Others (disabled when a single tab
/// remains), Close to the Right (disabled when the chip is the last tab),
/// Close All.
///
/// Action closures are plain `() -> Void` so the menu stays agnostic of
/// the reducer. `TabChipView` converts each into the matching
/// `TabBarFeature.Action` dispatch at its call site.
struct TabChipContextMenu: View {
  let isOnlyTab: Bool
  let isLastTab: Bool
  let onCopyID: () -> Void
  let onClose: () -> Void
  let onCloseOthers: () -> Void
  let onCloseToRight: () -> Void
  let onCloseAll: () -> Void

  var body: some View {
    Button("Copy Tab ID", action: onCopyID)
    Divider()
    Button("Close Tab", action: onClose)
    Button("Close Other Tabs", action: onCloseOthers)
      .disabled(isOnlyTab)
    Button("Close Tabs to the Right", action: onCloseToRight)
      .disabled(isLastTab)
    Divider()
    Button("Close All Tabs", action: onCloseAll)
  }
}
