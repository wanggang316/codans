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
/// commands, Global commands, Config Files (one submenu per manifest, plus
/// Refresh), then the two Manage footers. Empty sections are omitted.
enum RunMenuBuilder {
  static func populate(_ menu: NSMenu, with model: RunMenuModel, delegate: NSMenuDelegate?) {
    menu.removeAllItems()
    menu.autoenablesItems = false

    var needsSeparator = false
    func separateIfNeeded() {
      if needsSeparator { menu.addItem(.separator()) }
      needsSeparator = false
    }

    for (title, commands) in [("Project", model.projectCommands), ("Global", model.globalCommands)]
    where !commands.isEmpty {
      menu.addItem(.sectionHeader(title: title))
      for command in commands { menu.addItem(commandItem(command)) }
      needsSeparator = true
    }

    if !model.configFiles.isEmpty || model.isScanning {
      separateIfNeeded()
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
        for entry in file.entries { submenu.addItem(entryItem(entry)) }
        parent.submenu = submenu
        menu.addItem(parent)
      }
      if let refresh = model.refresh {
        menu.addItem(NSMenuItem.closure(title: "Refresh", handler: refresh))
      }
      needsSeparator = true
    }

    separateIfNeeded()
    menu.addItem(NSMenuItem.closure(title: "Manage Project Commands…", handler: model.manageProjectCommands))
    menu.addItem(NSMenuItem.closure(title: "Manage Global Commands…", handler: model.manageGlobalCommands))
  }

  private static func commandItem(_ command: RunMenuModel.Command) -> NSMenuItem {
    let item = NSMenuItem.closure(title: command.title, handler: command.perform)
    let row = RunMenuRowView(
      content: .init(
        icon: CommandIconImage.tinted(command.icon, color: command.tint, pointSize: RunMenuMetrics.iconPointSize),
        highlightedIcon: highlightedIcon(command.icon),
        title: command.title,
        trailingText: command.chord
      ),
      height: RunMenuMetrics.commandRowHeight
    )
    row.onRun = command.perform
    item.view = row
    return item
  }

  private static func entryItem(_ entry: RunMenuModel.Entry) -> NSMenuItem {
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
      height: RunMenuMetrics.entryRowHeight
    )
    row.onRun = entry.run
    row.onAdd = entry.add
    item.view = row
    return item
  }

  private static func highlightedIcon(_ icon: CommandIconRef) -> NSImage? {
    CommandIconImage.tinted(icon, color: .selectedMenuItemTextColor, pointSize: RunMenuMetrics.iconPointSize)
  }
}
