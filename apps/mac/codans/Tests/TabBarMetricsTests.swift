import CoreGraphics
import Testing

@testable import Codans

/// The narrow-strip rule: history folds into the `+` menu once the full
/// accessory cluster would leave the track less than one minimum-width chip.
@MainActor
struct TabBarMetricsTests {
  /// Leading inset 6 + one 120-pt chip + 4-pt gap + two 22-pt buttons with
  /// one 4-pt gap and 6-pt padding on each side.
  private static let threshold: CGFloat = 6 + 120 + 4 + (2 * 22 + 4 + 2 * 6)

  @Test
  func thresholdIsOneChipPlusTheFullCluster() {
    #expect(Self.threshold == 190)
    #expect(TabBarMetrics.accessoryClusterWidth(count: 2) == 60)
    #expect(TabBarMetrics.accessoryClusterWidth(count: 1) == 34)
    #expect(TabBarMetrics.accessoryClusterWidth(count: 0) == 0)
  }

  @Test(arguments: [
    (CGFloat(0), true),
    (100, true),
    (189.5, true),
    (190, false),
    (600, false),
    (.infinity, false),
  ])
  func foldsBelowTheThreshold(width: CGFloat, folds: Bool) {
    #expect(TabBarMetrics.foldsAccessories(stripWidth: width) == folds)
  }
}
