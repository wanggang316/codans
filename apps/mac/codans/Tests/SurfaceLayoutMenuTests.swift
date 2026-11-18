import AppKit
import CodansCore
import Testing

@testable import Codans

/// The terminal surface's right-click and Pane header Layout submenu.
@MainActor
struct SurfaceLayoutMenuTests {
  private final class Target: NSObject {
    @objc func select(_ sender: NSMenuItem) {}
  }

  @Test
  func layoutSubmenuStartsWithPlaceAndShowsItsEffectiveChord() throws {
    let target = Target()
    let item = GhosttySurfaceView.makeLayoutMenuItem(
      target: target,
      placePickerAction: #selector(Target.select(_:)),
      placeAction: #selector(Target.select(_:)),
      keyEquivalent: { command in
        command == .placePane ? MenuKeyEquivalent(key: "k", modifiers: [.command, .option]) : nil
      })
    let submenu = try #require(item.submenu)
    let place = try #require(submenu.items.first)
    #expect(place.title == "Place…")
    #expect(place.keyEquivalent == "k")
    #expect(place.keyEquivalentModifierMask == [.command, .option])
    #expect(place.accessibilityIdentifier() == "pane_hud.place_picker")
    #expect(place.target === target)
    #expect(submenu.items[1].isSeparatorItem)
    let regions = submenu.items.compactMap { $0.representedObject as? PlaceRegion }
    #expect(regions == PlaceRegion.groups.flatMap { $0 })
  }
}
