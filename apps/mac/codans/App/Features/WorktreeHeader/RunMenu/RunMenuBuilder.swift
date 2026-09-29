import AppKit
import CodansCore

/// Target for a closure-backed `NSMenuItem`. Stored as the item's
/// `representedObject`, since `target` is weak.
final class MenuActionTrampoline: NSObject {
  private let handler: () -> Void

  init(_ handler: @escaping () -> Void) {
    self.handler = handler
  }

  @objc func invoke(_ sender: Any?) { handler() }
}

extension NSMenuItem {
  /// Stock item that runs `handler`. View-backed rows use it only for
  /// their title (accessibility, type-to-select); they act on their own.
  static func closure(title: String, handler: @escaping () -> Void) -> NSMenuItem {
    let trampoline = MenuActionTrampoline(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuActionTrampoline.invoke(_:)), keyEquivalent: "")
    item.target = trampoline
    item.representedObject = trampoline
    return item
  }
}

/// Turns a `RunMenuModel` into menu items. Layout, top to bottom: Project
/// commands closed by Manage Project Commands…, Global commands closed by
/// Manage Global Commands…, then Config Files (one submenu per manifest,
/// plus Refresh) when there is anything to show. The Project and Global
/// groups always appear, so their Manage items stay reachable when empty.
enum RunMenuBuilder {
  /// Marks the Project/Global block, so it can be swapped while the menu
  /// stays open.
  private static let commandBlockTag = 0x52_554E  // "RUN"

  /// `onEntryAdded` runs after any Config Files entry is added.
  static func populate(
    _ menu: NSMenu, with model: RunMenuModel, delegate: NSMenuDelegate?, onEntryAdded: @escaping () -> Void = {}
  ) {
    menu.removeAllItems()
    menu.autoenablesItems = false
    // One hidden slot per entry that can still be added from this menu,
    // so each add can take a slot instead of growing the block.
    let addable = model.configFiles.reduce(0) { $0 + $1.entries.filter { !$0.isAdded }.count }
    for item in commandBlock(model, placeholders: addable) { menu.addItem(item) }

    if !model.configFiles.isEmpty || model.isScanning {
      menu.addItem(.separator())
      menu.addItem(.sectionHeader(title: "Config Files"))
      if model.configFiles.isEmpty {
        let scanning = NSMenuItem(title: "Scanning…", action: nil, keyEquivalent: "")
        scanning.isEnabled = false
        menu.addItem(scanning)
      }
      for file in model.configFiles {
        let parent = NSMenuItem(title: file.title, action: nil, keyEquivalent: "")
        // Template, so a highlighted file item inverts its icon with its title.
        parent.image = file.icon.flatMap { CommandIconImage.template($0, pointSize: RunMenuMetrics.iconPointSize) }
        let submenu = NSMenu(title: file.title)
        submenu.autoenablesItems = false
        submenu.delegate = delegate
        for entry in file.entries { submenu.addItem(entryItem(entry, onAdded: onEntryAdded)) }
        parent.submenu = submenu
        menu.addItem(parent)
      }
      if let refresh = model.refresh {
        menu.addItem(NSMenuItem.closure(title: "Refresh", handler: refresh))
      }
    }
  }

  /// Replaces only the Project/Global block of an open menu; the Config
  /// Files items below it are left in place, at the same indices. AppKit
  /// keeps an open menu's highlight as an index, so the block is padded
  /// back to its previous item count with hidden slots — otherwise a new
  /// row would move the highlight off the Config Files item under the
  /// pointer.
  static func refreshCommands(in menu: NSMenu, with model: RunMenuModel) {
    let previousCount = menu.items.filter { $0.tag == commandBlockTag }.count
    for item in menu.items where item.tag == commandBlockTag {
      menu.removeItem(item)
    }
    let rows = commandBlock(model, placeholders: 0)
    let block = commandBlock(model, placeholders: max(0, previousCount - rows.count))
    for (offset, item) in block.enumerated() {
      menu.insertItem(item, at: offset)
    }
  }

  /// Both command groups, each a header, its rows and its Manage item,
  /// followed by `placeholders` hidden slots.
  private static func commandBlock(_ model: RunMenuModel, placeholders: Int) -> [NSMenuItem] {
    var items: [NSMenuItem] = [.sectionHeader(title: "Project")]
    items += model.projectCommands.map(commandItem)
    items.append(NSMenuItem.closure(title: "Manage Project Commands…", handler: model.manageProjectCommands))
    items.append(.separator())
    items.append(.sectionHeader(title: "Global"))
    items += model.globalCommands.map(commandItem)
    items.append(NSMenuItem.closure(title: "Manage Global Commands…", handler: model.manageGlobalCommands))
    for _ in 0..<placeholders {
      let slot = NSMenuItem(title: "", action: nil, keyEquivalent: "")
      slot.isHidden = true
      items.append(slot)
    }
    for item in items { item.tag = commandBlockTag }
    return items
  }

  private static func commandItem(_ command: RunMenuModel.Command) -> NSMenuItem {
    let item = NSMenuItem.closure(title: command.title, handler: command.perform)
    let row = RunMenuRowView(
      content: .init(
        icon: CommandIconImage.tinted(command.icon, color: command.tint, pointSize: RunMenuMetrics.iconPointSize),
        highlightedIcon: highlightedIcon(command.icon),
        title: command.title,
        subtitle: command.subtitle,
        trailingText: command.chord
      ),
      height: RunMenuMetrics.rowHeight
    )
    row.onRun = command.perform
    item.view = row
    return item
  }

  private static func entryItem(_ entry: RunMenuModel.Entry, onAdded: @escaping () -> Void) -> NSMenuItem {
    // The title is not drawn (the view is) but names the item for
    // accessibility and type-to-select.
    let item = NSMenuItem.closure(title: entry.title, handler: entry.run)
    item.toolTip = entry.subtitle
    let row = RunMenuRowView(
      content: .init(
        icon: CommandIconImage.tinted(entry.icon, color: entry.tint, pointSize: RunMenuMetrics.iconPointSize),
        highlightedIcon: highlightedIcon(entry.icon),
        title: entry.title,
        subtitle: entry.subtitle,
        accessory: entry.isAdded ? .added : .add
      ),
      height: RunMenuMetrics.rowHeight
    )
    row.onRun = entry.run
    row.onAdd = {
      entry.add()
      onAdded()
    }
    item.view = row
    return item
  }

  private static func highlightedIcon(_ icon: CommandIconRef) -> NSImage? {
    CommandIconImage.tinted(icon, color: .selectedMenuItemTextColor, pointSize: RunMenuMetrics.iconPointSize)
  }
}
