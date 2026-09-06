import Foundation
import Testing

@testable import CodansCore

struct HandoffPlacementTests {
  @Test
  func wireFieldsMapOntoTheTwoPlacements() {
    #expect(HandoffPlacement(target: nil, direction: nil) == .newTab)
    #expect(HandoffPlacement(target: .newTab, direction: .down) == .newTab)
    #expect(HandoffPlacement(target: .split, direction: nil) == .split(.right))
    #expect(HandoffPlacement(target: .split, direction: .down) == .split(.down))
  }

  /// A hand-off must never type over the outgoing agent's pane.
  @Test
  func focusedIsNotAHandoffPlacement() {
    #expect(HandoffPlacement(target: .focused, direction: nil) == nil)
  }

  @Test
  func cliArgumentsAreEmptyForTheDefaultAndNameTheSplitDirection() {
    #expect(HandoffPlacement.newTab.cliArguments.isEmpty)
    #expect(HandoffPlacement.split(.left).cliArguments == ["--split", "left"])
    #expect(HandoffPlacement.default == .newTab)
  }

  @Test
  func persistedTokenRoundTrips() {
    for placement in [HandoffPlacement.newTab, .split(.right), .split(.up)] {
      #expect(HandoffPlacement(persisted: placement.persisted) == placement)
    }
    #expect(HandoffPlacement(persisted: "split:sideways") == nil)
    #expect(HandoffPlacement(persisted: "") == nil)
  }
}
