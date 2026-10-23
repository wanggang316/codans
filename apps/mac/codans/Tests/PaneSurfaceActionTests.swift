import Foundation
import Testing

@testable import Codans

/// `PaneSurfaceAction` exists so the surface's right-click menu and the tab
/// chip's actions menu cannot drift apart. Both renderers walk `groups`, so these pin
/// the properties that keep "walk groups" equivalent to "offer everything".
struct PaneSurfaceActionTests {
  /// The renderers iterate `groups`, never `allCases`. An action added to
  /// the enum but left out of a group would silently appear in neither menu.
  @Test
  func groupsCoverEveryAction() {
    let grouped = PaneSurfaceAction.groups.flatMap { $0 }
    #expect(Set(grouped) == Set(PaneSurfaceAction.allCases))
    #expect(grouped.count == PaneSurfaceAction.allCases.count)
  }

  /// Close is last wherever the list is rendered: teardown sits alone at the
  /// bottom, under its own separator.
  @Test
  func closeIsTheLastGroupOnItsOwn() {
    #expect(PaneSurfaceAction.groups.last == [.close])
  }

  /// Copy is the only action gated on a selection; everything else is always
  /// offered. The right-click menu drops a gated item, the chip menu disables it,
  /// and both ask this.
  @Test
  func onlyCopyNeedsASelection() {
    let gated = PaneSurfaceAction.allCases.filter(\.needsSelection)
    #expect(gated == [.copy])
  }

  /// Every row draws a glyph, so a missing symbol would leave one row's text
  /// hanging where the others have an icon column.
  @Test
  func everyActionCarriesATitleAndSymbol() {
    for action in PaneSurfaceAction.allCases {
      #expect(!action.title.isEmpty)
      #expect(!action.symbol.isEmpty)
    }
  }
}
