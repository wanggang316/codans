import AppKit
import ComposableArchitecture
import Observation

/// Uses window toolbar controls so the comparison surface stays focused on code.
@MainActor
final class DiffWindowToolbar: NSObject, NSToolbarDelegate {
  private let store: StoreOf<DiffFeature>
  private let layoutID = NSToolbarItem.Identifier("diff.layout")
  private let refreshID = NSToolbarItem.Identifier("diff.refresh")
  private var layout: NSToolbarItemGroup?

  init(store: StoreOf<DiffFeature>) {
    self.store = store
    super.init()
  }

  func makeToolbar() -> NSToolbar {
    let toolbar = NSToolbar(identifier: "DiffWindowToolbar")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    synchronize()
    return toolbar
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.flexibleSpace, layoutID, refreshID]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch identifier {
    case layoutID:
      let item = NSToolbarItemGroup(
        itemIdentifier: identifier,
        images: [
          NSImage(systemSymbolName: "rectangle", accessibilityDescription: "Unified Diff") ?? NSImage(),
          NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split Diff") ?? NSImage(),
        ], selectionMode: .selectOne, labels: ["Unified Diff", "Split Diff"],
        target: self, action: #selector(changeLayout(_:)))
      item.label = "Diff Layout"
      item.selectedIndex = store.layout == "split" ? 1 : 0
      layout = item
      return item
    case refreshID:
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.label = "Refresh"
      item.toolTip = "Refresh changes"
      item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Changes")
      item.target = self
      item.action = #selector(refresh)
      return item
    default:
      return nil
    }
  }

  private func synchronize() {
    withObservationTracking {
      let selectedLayout = store.layout == "split" ? 1 : 0
      layout?.selectedIndex = selectedLayout
    } onChange: { [weak self] in
      Task { @MainActor in self?.synchronize() }
    }
  }

  @objc private func changeLayout(_ sender: NSToolbarItemGroup) {
    store.send(.layoutChanged(sender.selectedIndex == 1 ? "split" : "unified"))
  }

  @objc private func refresh() { store.send(.refresh) }
}
