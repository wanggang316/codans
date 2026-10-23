import AppKit
import SwiftUI

/// One row of a pull-down menu the tab bar drops from a control: the `+`
/// button's menu and a chip's actions menu.
struct PullDownMenuItem {
  enum Kind {
    case action(title: String, image: NSImage?, isEnabled: Bool, perform: () -> Void)
    case separator
  }

  let kind: Kind

  static func action(
    _ title: String, image: NSImage? = nil, isEnabled: Bool = true, perform: @escaping () -> Void
  ) -> PullDownMenuItem {
    PullDownMenuItem(kind: .action(title: title, image: image, isEnabled: isEnabled, perform: perform))
  }

  static let separator = PullDownMenuItem(kind: .separator)
}

extension NSMenu {
  /// A menu of `items` that keeps each item's closure alive as long as the
  /// menu is.
  convenience init(pullDownItems items: [PullDownMenuItem]) {
    self.init()
    autoenablesItems = false
    for item in items {
      switch item.kind {
      case .separator:
        addItem(.separator())
      case .action(let title, let image, let isEnabled, let perform):
        let menuItem = NSMenuItem(
          title: title, action: #selector(ClosureMenuTarget.invoke), keyEquivalent: "")
        let target = ClosureMenuTarget(perform)
        menuItem.target = target
        // NSMenuItem holds its target weakly; the represented object keeps
        // the closure box alive for as long as the menu is.
        menuItem.representedObject = target
        menuItem.image = image
        menuItem.isEnabled = isEnabled
        addItem(menuItem)
      }
    }
  }

  /// Drops the menu from `view`'s bottom-left edge, like a pull-down.
  func popUpBelow(_ view: NSView) {
    popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
  }
}

/// AppKit overlay that opens a pull-down menu on a primary or secondary
/// press. SwiftUI cannot open a menu programmatically at a control, so the
/// press is handled here and the SwiftUI button underneath keeps the chrome,
/// hover state, tooltip, and accessibility.
struct PullDownMenuOverlay: NSViewRepresentable {
  /// Built at the moment the menu opens, so it reflects the current state.
  let menuItems: () -> [PullDownMenuItem]

  func makeNSView(context: Context) -> PullDownMenuCatcher {
    let view = PullDownMenuCatcher()
    view.menuItems = menuItems
    return view
  }

  func updateNSView(_ nsView: PullDownMenuCatcher, context: Context) {
    nsView.menuItems = menuItems
  }
}

/// Claims only primary / secondary button presses; hover and every other
/// event fall through to the SwiftUI content underneath.
final class PullDownMenuCatcher: NSView {
  var menuItems: (() -> [PullDownMenuItem])?

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let event = NSApp.currentEvent else { return nil }
    switch event.type {
    case .leftMouseDown, .rightMouseDown:
      return super.hitTest(point)
    default:
      return nil
    }
  }

  override func mouseDown(with event: NSEvent) {
    showMenu()
  }

  override func rightMouseDown(with event: NSEvent) {
    showMenu()
  }

  private func showMenu() {
    guard let items = menuItems?(), !items.isEmpty else { return }
    NSMenu(pullDownItems: items).popUpBelow(self)
  }
}

/// AppKit overlay for the tab bar's `+`: a click runs `onClick`, while a
/// press-and-hold or a right-click drops the menu below the button. SwiftUI
/// can neither tell a long press from a click on a `Button` (the button still
/// fires on release) nor open a menu programmatically, so the pointer is
/// handled here and the SwiftUI button underneath keeps the chrome, hover
/// state, tooltip, and accessibility press.
struct NewTabMenuOverlay: NSViewRepresentable {
  let onClick: () -> Void
  /// Built at the moment the menu opens so it reflects current settings.
  let menuItems: () -> [PullDownMenuItem]

  func makeNSView(context: Context) -> NewTabMenuCatcher {
    let view = NewTabMenuCatcher()
    view.onClick = onClick
    view.menuItems = menuItems
    return view
  }

  func updateNSView(_ nsView: NewTabMenuCatcher, context: Context) {
    nsView.onClick = onClick
    nsView.menuItems = menuItems
  }
}

/// Claims only primary / secondary button presses; hover and every other
/// event fall through to the SwiftUI content underneath.
final class NewTabMenuCatcher: NSView {
  /// Hold time that turns a press into "open the menu", matching the
  /// press-and-hold delay of AppKit's pull-down toolbar buttons.
  static let holdDuration: TimeInterval = 0.35

  var onClick: (() -> Void)?
  var menuItems: (() -> [PullDownMenuItem])?

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let event = NSApp.currentEvent else { return nil }
    switch event.type {
    case .leftMouseDown, .rightMouseDown:
      return super.hitTest(point)
    default:
      return nil
    }
  }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return }
    let deadline = Date(timeIntervalSinceNow: Self.holdDuration)
    // Local tracking loop: a release before the deadline is a click, no
    // release by then opens the menu while the button is still held.
    while let next = window.nextEvent(
      matching: [.leftMouseUp, .leftMouseDragged], until: deadline, inMode: .eventTracking,
      dequeue: true)
    {
      if next.type == .leftMouseUp {
        let location = convert(next.locationInWindow, from: nil)
        if bounds.contains(location) { onClick?() }
        return
      }
    }
    showMenu()
  }

  override func rightMouseDown(with event: NSEvent) {
    showMenu()
  }

  private func showMenu() {
    guard let items = menuItems?(), !items.isEmpty else { return }
    NSMenu(pullDownItems: items).popUpBelow(self)
  }
}

private final class ClosureMenuTarget: NSObject {
  let perform: () -> Void

  init(_ perform: @escaping () -> Void) {
    self.perform = perform
  }

  @objc func invoke() {
    perform()
  }
}
