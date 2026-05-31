import SwiftUI
import TouchCodeCore

/// Right-click context menu for a tab chip. Built as a `@ViewBuilder` so
/// `TabChipView` can attach it with `.contextMenu { TabChipContextMenu(…) }`
/// without a ViewModifier round-trip. The items reflect the plan's menu
/// surface: Rename, Close, Close Others (disabled when a single tab
/// remains), Close to the Right (disabled when the chip is the last tab),
/// Close All.
///
/// Action closures are plain `() -> Void` so the menu stays agnostic of
/// the reducer. `TabChipView` converts each into the matching
/// `TabBarFeature.Action` dispatch at its call site.
struct TabChipContextMenu: View {
  let isOnlyTab: Bool
  let isLastTab: Bool
  let onRename: () -> Void
  let onChangeColor: () -> Void
  let onChangeIcon: () -> Void
  let onCopyID: () -> Void
  let onClose: () -> Void
  let onCloseOthers: () -> Void
  let onCloseToRight: () -> Void
  let onCloseAll: () -> Void

  var body: some View {
    // Chord hint surfaces ⌘⇧R (or whatever the user has rebound it to)
    // beside the menu item. The chord targets the *active* tab, so a
    // right-click on an inactive tab still renames that specific tab via
    // the closure path; the hint stays advisory in that case.
    Button("Rename…", action: onRename)
      .appKeyboardShortcut(.renameActiveTab)
    Button("Change Color…", action: onChangeColor)
      .appKeyboardShortcut(.changeActiveTabColor)
    Button("Change Icon…", action: onChangeIcon)
    Divider()
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
