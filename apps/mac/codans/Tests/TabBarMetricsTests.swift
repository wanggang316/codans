import CoreGraphics
import Testing

@testable import Codans

/// The narrow-strip rule: history and the split buttons fold into the `+`
/// menu once the full accessory cluster would leave the track less than
/// one minimum-width chip.
@MainActor
struct TabBarMetricsTests {
  /// Leading inset 4 + one 120-pt chip + 4-pt gap + four 22-pt buttons with
  /// three 4-pt gaps and 6-pt padding on each side.
  private static let threshold: CGFloat = 4 + 120 + 4 + (4 * 22 + 3 * 4 + 2 * 6)

  @Test
  func thresholdIsOneChipPlusTheFullCluster() {
    #expect(Self.threshold == 240)
    #expect(TabBarMetrics.accessoryClusterWidth(count: 4) == 112)
    #expect(TabBarMetrics.accessoryClusterWidth(count: 1) == 34)
    #expect(TabBarMetrics.accessoryClusterWidth(count: 0) == 0)
  }

  @Test(arguments: [
    (CGFloat(0), true),
    (100, true),
    (239.5, true),
    (240, false),
    (600, false),
    (.infinity, false),
  ])
  func foldsBelowTheThreshold(width: CGFloat, folds: Bool) {
    #expect(TabBarMetrics.foldsAccessories(stripWidth: width) == folds)
  }
}
