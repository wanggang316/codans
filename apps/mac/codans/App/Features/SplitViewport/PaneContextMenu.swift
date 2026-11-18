import ComposableArchitecture
import SwiftUI
import CodansCore

/// Pure model for the pane right-click context menu. Side effects (reading
/// labels, flipping mute, closing the pane) go through closures so the
/// menu's logic stays testable without spinning up a SwiftUI view tree.
struct PaneContextMenuModel {
  let paneID: PaneID
  let snapshot: () -> Catalog
  let setLabel: (PaneID, String, Bool) -> Void
  /// Tears down the pane through `HierarchyClient.closePane`. The full
  /// pane address is captured by the view at the call site, so the model
  /// only needs to fire the closure. Defaults to a no-op so label-only
  /// tests can construct the model without wiring close.
  var closePane: () -> Void = {}
  /// Focuses a Pane of this pane's Tab and makes it first responder.
  var focusPane: (PaneID) -> Void = { _ in }
  /// Opens the Layout picker for this pane's Tab.
  var arrangeLayout: () -> Void = {}
  /// Moves a pane into a region of its Tab (Place) and keeps it focused.
  var placePane: (PaneID, PlaceRegion) -> Void = { _, _ in }
  /// Opens the Place picker for this pane.
  var openPlacePicker: () -> Void = {}

  var isMuted: Bool {
    snapshot().pane(paneID)?.isNotificationsMuted ?? false
  }

  func toggleMute() {
    setLabel(paneID, InboxLabels.muted, !isMuted)
  }

  func close() {
    closePane()
  }

  /// The Pane with Pane number `number` in this pane's Tab, or `nil` when
  /// the Tab has no Pane with that number.
  func pane(number: Int) -> PaneID? {
    let tab = snapshot().projects.lazy
      .flatMap(\.worktrees).flatMap(\.tabs)
      .first { $0.splitTree.contains(paneID) }
    return tab?.splitTree.leaf(paneNumber: number)
  }

  /// `true` when this pane's Tab has two or more Panes, the minimum the
  /// Layout picker arranges.
  var canArrange: Bool {
    pane(number: 2) != nil
  }

  /// `true` when this pane's Tab has two or more Panes; a one-Pane Tab
  /// ignores Place.
  var canPlace: Bool { canArrange }

  /// Places this pane (the one right-clicked) in `region`.
  func place(in region: PlaceRegion) {
    guard canPlace else { return }
    placePane(paneID, region)
  }

  /// Opens the Place picker for this pane (the one right-clicked).
  func placeWithPicker() {
    guard canPlace else { return }
    openPlacePicker()
  }

  func focusPane(number: Int) {
    guard let target = pane(number: number) else { return }
    focusPane(target)
  }
}

/// Right-click menu for a pane. Hosts the "Mute notifications" toggle,
/// the Layout submenu (Arrange…, Place…, Place this pane, and Focus Pane
/// 1…9 of this pane's Tab),
/// and a "Close" item that tears the pane down; future menu items can be
/// added here without churning `LazyPaneHost`.
///
/// The menu reads `HierarchyClient.snapshot()` lazily inside
/// `PaneContextMenuModel.isMuted` on every render so the checkmark
/// reflects the latest label state when the user re-opens the menu —
/// the per-pane mute label flips elsewhere are picked up without an
/// explicit observer.
struct PaneContextMenu: View {
  let paneID: PaneID
  let tabID: TabID
  let worktreeID: WorktreeID
  let projectID: ProjectID
  @Dependency(HierarchyClient.self) private var hierarchy
  @Environment(\.openLayoutPicker) private var openLayoutPicker
  @Environment(\.openPlacePicker) private var openPlacePicker

  private var model: PaneContextMenuModel {
    PaneContextMenuModel(
      paneID: paneID,
      snapshot: hierarchy.snapshot,
      setLabel: hierarchy.setPaneLabel,
      // Mirrors the ⌘W focused-pane path (RootFeature) and the prepared
      // `SplitViewportFeature.closePaneButtonTapped`: a plain pane
      // teardown. Closing the tab's last pane leaves an empty tab, which
      // `SplitViewportView` renders as its "No panes" placeholder.
      closePane: { try? hierarchy.closePane(paneID, tabID, worktreeID, projectID) },
      focusPane: { target in
        try? hierarchy.focusPane(target, tabID, worktreeID, projectID)
        hierarchy.focusSurfaceView(target)
      },
      arrangeLayout: { [openLayoutPicker, paneID] in openLayoutPicker(paneID) },
      // Same effect as `PaneActionRouterFeature`'s `.place`: reshape, then
      // give input back to the placed pane.
      placePane: { target, region in
        try? hierarchy.placePane(target, region)
        hierarchy.focusSurfaceView(target)
      },
      openPlacePicker: { [openPlacePicker, paneID] in openPlacePicker(paneID) }
    )
  }

  var body: some View {
    Button {
      model.toggleMute()
    } label: {
      Label(
        "Mute notifications",
        systemImage: model.isMuted ? "checkmark" : "bell.slash"
      )
    }
    Divider()
    // The Layout submenu, in the order of Window ▸ Layout.
    Menu("Layout") {
      Button("Arrange…") {
        model.arrangeLayout()
      }
      .appKeyboardShortcut(.arrangeLayout)
      .disabled(!model.canArrange)
      Button("Place…") {
        model.placeWithPicker()
      }
      .appKeyboardShortcut(.placePane)
      .disabled(!model.canPlace)
      ForEach(PlaceRegion.groups, id: \.self) { group in
        Divider()
        ForEach(group, id: \.self) { region in
          Button(region.title) {
            model.place(in: region)
          }
          .appKeyboardShortcut(.place(region))
          .disabled(!model.canPlace)
        }
      }
      Divider()
      ForEach(Array(SplitTree<PaneID>.paneNumbers), id: \.self) { number in
        if let id = CommandID.focusPane(number: number) {
          Button("Focus Pane \(number)") {
            model.focusPane(number: number)
          }
          .appKeyboardShortcut(id)
          .disabled(model.pane(number: number) == nil)
        }
      }
    }
    Divider()
    Button {
      model.close()
    } label: {
      Label("Close", systemImage: "xmark")
    }
  }
}
