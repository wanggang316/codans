import AppKit
import SwiftUI

/// One row of the Open In dropdown.
struct OpenInMenuEntry {
  let title: String
  let image: NSImage?
  var toolTip: String?
  var isEnabled = true
  let action: () -> Void
}

/// The Open In toolbar split button, built like `RunSplitButton` from the AppKit control
/// SwiftUI uses for a toolbar `Menu(primaryAction:)`. AppKit redraws a SwiftUI `Menu`
/// label from its image and text and keeps no SwiftUI styling, so a hint there cannot
/// replace the icon or use the hint font. Here the primary segment's image is set
/// directly: the editor icon, or the chord in the hint style while ⌘ is held.
struct OpenInSplitButton: NSViewRepresentable {
  let icon: NSImage?
  /// The chord while ⌘ is held, else `nil`. Takes the icon's place.
  let chordHint: String?
  let toolTip: String
  let accessibilityLabel: String
  let onPrimary: () -> Void
  /// Dropdown rows in groups, with a separator between groups. Built each time the
  /// menu opens, so the rows read live state.
  let makeMenu: () -> [[OpenInMenuEntry]]

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> RunSegmentedControl {
    let control = RunSegmentedControl()
    control.segmentCount = 2
    control.segmentStyle = .texturedRounded
    control.trackingMode = .momentary
    control.segmentDistribution = .fit
    control.controlSize = Self.toolbarControlSize
    control.setWidth(24, forSegment: 1)
    control.setShowsMenuIndicator(true, forSegment: 1)
    control.setImageScaling(.scaleNone, forSegment: 0)
    control.setToolTip("Open in…", forSegment: 1)
    control.wantsLayer = true
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = context.coordinator
    control.setMenu(menu, forSegment: 1)
    control.target = context.coordinator
    control.action = #selector(Coordinator.segmentClicked(_:))
    control.onPrimaryClick = { [coordinator = context.coordinator] in coordinator.onPrimary() }
    return control
  }

  func updateNSView(_ control: RunSegmentedControl, context: Context) {
    let coordinator = context.coordinator
    coordinator.onPrimary = onPrimary
    coordinator.makeMenu = makeMenu
    let image = chordHint.map { ShortcutHintImage.image(of: $0) } ?? icon
    if control.image(forSegment: 0) !== image {
      // The icon and the chord swap by a cross-fade in place: quick when ⌘ goes down,
      // slower when the icon comes back.
      if coordinator.hasImage, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = chordHint == nil ? 0.1 : 0.04
        control.layer?.add(fade, forKey: "shortcutHint")
      }
      control.setImage(image, forSegment: 0)
      coordinator.hasImage = image != nil
      control.invalidateIntrinsicContentSize()
    }
    control.setToolTip(toolTip, forSegment: 0)
    control.setAccessibilityLabel(accessibilityLabel)
    (control.cell as? NSSegmentedCell)?.setAccessibilityLabel(accessibilityLabel)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: RunSegmentedControl, context: Context) -> CGSize? {
    nsView.intrinsicContentSize
  }

  /// SwiftUI's own toolbar split uses the extra-large size on macOS 26.
  private static var toolbarControlSize: NSControl.ControlSize {
    if #available(macOS 26.0, *) { return .extraLarge }
    return .large
  }

  final class Coordinator: NSObject, NSMenuDelegate {
    var onPrimary: () -> Void = {}
    var makeMenu: () -> [[OpenInMenuEntry]] = { [] }
    var hasImage = false

    @objc func segmentClicked(_ sender: NSSegmentedControl) {
      if sender.selectedSegment == 0 {
        onPrimary()
        return
      }
      // Mouse presses never get here (see `RunSegmentedControl`); a keyboard or
      // accessibility press does, so open the menu under the control ourselves.
      guard let menu = sender.menu(forSegment: 1) else { return }
      let origin = NSPoint(x: sender.bounds.maxX - sender.width(forSegment: 1), y: sender.bounds.maxY + 4)
      menu.popUp(positioning: nil, at: sender.isFlipped ? origin : NSPoint(x: origin.x, y: -4), in: sender)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
      menu.removeAllItems()
      for (index, group) in makeMenu().enumerated() {
        if index > 0 { menu.addItem(.separator()) }
        for entry in group {
          let item = NSMenuItem(title: entry.title, action: #selector(runEntry(_:)), keyEquivalent: "")
          item.target = self
          item.image = entry.image
          item.toolTip = entry.toolTip
          item.isEnabled = entry.isEnabled
          item.representedObject = OpenInMenuAction(entry.action)
          menu.addItem(item)
        }
      }
    }

    @objc private func runEntry(_ item: NSMenuItem) {
      (item.representedObject as? OpenInMenuAction)?.run()
    }
  }
}

/// Carries an entry's closure on its menu item (`representedObject`).
private final class OpenInMenuAction {
  let run: () -> Void

  init(_ run: @escaping () -> Void) {
    self.run = run
  }
}
