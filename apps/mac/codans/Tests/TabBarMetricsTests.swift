import CoreGraphics
import Testing

@testable import Codans

/// The narrow-strip rule: history folds into the `+` menu once the full
/// accessory cluster would leave the track less than one minimum-width chip.
@MainActor
struct TabBarMetricsTests {
  /// Leading inset 4 + one 120-pt chip + 4-pt gap + two 22-pt buttons with
  /// one 4-pt gap and 4-pt padding on each side.
  private static let threshold: CGFloat = 4 + 120 + 4 + (2 * 22 + 4 + 2 * 4)

  @Test
  func thresholdIsOneChipPlusTheFullCluster() {
    #expect(Self.threshold == 184)
    #expect(TabBarMetrics.accessoryClusterWidth(count: 2) == 56)
    #expect(TabBarMetrics.accessoryClusterWidth(count: 1) == 30)
    #expect(TabBarMetrics.accessoryClusterWidth(count: 0) == 0)
  }

  @Test(arguments: [
    (CGFloat(0), true),
    (100, true),
    (183.5, true),
    (184, false),
    (600, false),
    (.infinity, false),
  ])
  func foldsBelowTheThreshold(width: CGFloat, folds: Bool) {
    #expect(TabBarMetrics.foldsAccessories(stripWidth: width) == folds)
  }
}
