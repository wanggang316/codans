import AppKit
import SwiftUI

/// The Run toolbar split button, as the AppKit control SwiftUI itself uses for
/// `Menu(primaryAction:)` in a toolbar: a two-segment `NSSegmentedControl`
/// (textured-rounded, momentary) whose second segment carries the dropdown.
/// Built here rather than through SwiftUI's `Menu` because that menu can only
/// hold stock items, and this one needs taller rows with a second click
/// target (see `RunMenuRowView`).
///
/// The menu is rebuilt from `makeMenu` every time it opens, so run state and
/// scan results are current without forcing SwiftUI to recreate the control.
struct RunSplitButton: NSViewRepresentable {
  /// Tinted, non-template glyph for the primary segment.
  let image: NSImage?
  /// Shortcut shown beside the glyph while ⌘ is held (`⌘R`, `⌘.`).
  let chordHint: String?
  let toolTip: String
  let accessibilityLabel: String
  let onPrimary: () -> Void
  let makeMenu: () -> RunMenuModel

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl()
    control.segmentCount = 2
    control.segmentStyle = .texturedRounded
    control.trackingMode = .momentary
    control.segmentDistribution = .fit
    control.controlSize = Self.toolbarControlSize
    control.setWidth(24, forSegment: 1)
    control.setShowsMenuIndicator(true, forSegment: 1)
    let menu = NSMenu()
    menu.delegate = context.coordinator
    control.setMenu(menu, forSegment: 1)
    control.target = context.coordinator
    control.action = #selector(Coordinator.segmentClicked(_:))
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    context.coordinator.onPrimary = onPrimary
    context.coordinator.makeMenu = makeMenu
    control.setImage(image, forSegment: 0)
    control.setLabel(chordHint ?? "", forSegment: 0)
    control.setImageScaling(.scaleNone, forSegment: 0)
    control.setToolTip(toolTip, forSegment: 0)
    control.setToolTip("More Commands", forSegment: 1)
    control.setAccessibilityLabel(accessibilityLabel)
    (control.cell as? NSSegmentedCell)?.setAccessibilityLabel(accessibilityLabel)
    control.image(forSegment: 0)?.accessibilityDescription = accessibilityLabel
    control.invalidateIntrinsicContentSize()
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
    nsView.intrinsicContentSize
  }

  /// SwiftUI's own toolbar split uses the extra-large size on macOS 26.
  private static var toolbarControlSize: NSControl.ControlSize {
    if #available(macOS 26.0, *) { return .extraLarge }
    return .large
  }

  final class Coordinator: NSObject, NSMenuDelegate {
    var onPrimary: () -> Void = {}
    var makeMenu: () -> RunMenuModel = { RunMenuModel() }

    @objc func segmentClicked(_ sender: NSSegmentedControl) {
      if sender.selectedSegment == 0 {
        onPrimary()
        return
      }
      // A mouse press on segment 1 has AppKit open its menu. A press from
      // the keyboard or an accessibility client (VoiceOver) only reaches
      // this action, so open the same menu under the control ourselves.
      let mouseTypes: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
      guard let menu = sender.menu(forSegment: 1),
        NSApp.currentEvent.map({ !mouseTypes.contains($0.type) }) ?? true
      else { return }
      let origin = NSPoint(x: sender.bounds.maxX - sender.width(forSegment: 1), y: sender.bounds.maxY + 4)
      menu.popUp(positioning: nil, at: sender.isFlipped ? origin : NSPoint(x: origin.x, y: -4), in: sender)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
      // Only the root menu is rebuilt; submenus arrive already populated.
      guard menu.supermenu == nil else { return }
      RunMenuBuilder.populate(menu, with: makeMenu(), delegate: self)
    }

    /// View-backed rows draw their own highlight, so repaint the rows
    /// entering and leaving it.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
      for candidate in menu.items where candidate.view != nil {
        candidate.view?.needsDisplay = true
      }
      item?.view?.needsDisplay = true
    }
  }
}
