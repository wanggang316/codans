import CoreGraphics
import Testing

@testable import Codans

/// `TabStackLayout` against frames sampled from AppKit's own tab bar
/// (`TabStackLayoutNativeSamples`), plus the scroll rules measured from it.
@MainActor
struct TabStackLayoutTests {
  private struct Sample {
    let count: Int
    let viewport: CGFloat
    let selected: Int
    let scroll: CGFloat
    let frames: [(x: CGFloat, width: CGFloat, hidden: Bool)]

    init(_ entry: String) {
      let parts = entry.split(separator: "|")
      count = Int(parts[0])!
      viewport = CGFloat(Double(parts[1])!)
      selected = Int(parts[2])!
      scroll = CGFloat(Double(parts[3])!)
      frames = parts[4].split(separator: ";").map { tab in
        let v = tab.split(separator: ",").map { Double($0)! }
        return (CGFloat(v[0]), CGFloat(v[1]), v[2] != 0)
      }
    }
  }

  @Test func matchesNativeFramesWithinOnePoint() {
    var compared = 0
    for entry in TabStackLayoutNativeSamples.entries {
      let sample = Sample(entry)
      let frames = TabStackLayout.frames(
        count: sample.count, selectedIndex: sample.selected,
        scrollOffset: sample.scroll, viewportWidth: sample.viewport)
      #expect(frames.count == sample.count)
      for (index, native) in sample.frames.enumerated() {
        // Only what is actually on screen is comparable.
        guard !native.hidden, native.width > 0, native.x < sample.viewport, native.x + native.width > 0
        else { continue }
        compared += 1
        let model = frames[index]
        // A 1-pt native sliver may round to zero width here — within tolerance.
        #expect(!model.isHidden || native.width <= 1, "\(entry.prefix(24))… tab \(index) should be visible")
        #expect(abs(model.x - native.x) <= 1, "\(entry.prefix(24))… tab \(index) x \(model.x) vs \(native.x)")
        #expect(
          abs(model.width - native.width) <= 1,
          "\(entry.prefix(24))… tab \(index) width \(model.width) vs \(native.width)")
      }
    }
    #expect(compared > 2500)
  }

  @Test func zoneScalesWithViewportAndCaps() {
    #expect(TabStackLayout.zone(viewportWidth: 700) == 87.5)
    #expect(TabStackLayout.zone(viewportWidth: 880) == 110)
    #expect(TabStackLayout.zone(viewportWidth: 1180) == 128)
  }

  @Test func selectedTabPinsToTheEdgeWhenNothingFollowsIt() {
    let frames = TabStackLayout.frames(count: 17, selectedIndex: 16, scrollOffset: 0, viewportWidth: 880)
    #expect(frames[16] == .init(x: 760, width: 120, isHidden: false))
  }

  @Test func stackClickScrollsByOnePage() {
    // Measured: 880-pt bar, click the leading stack at offset 600 → 115.
    #expect(
      TabStackLayout.scrollTarget(
        for: .leading, selectedIndex: 16, scrollOffset: 600, count: 17, viewportWidth: 880) == 115)
    #expect(
      TabStackLayout.scrollTarget(
        for: .trailing, selectedIndex: 16, scrollOffset: 150, count: 17, viewportWidth: 880) == 635)
    // Local stacks bring the selected tab to the unstacked area's edge.
    #expect(
      TabStackLayout.scrollTarget(
        for: .beforeSelected, selectedIndex: 8, scrollOffset: 0, count: 17, viewportWidth: 880) == 310)
    #expect(
      TabStackLayout.scrollTarget(
        for: .afterSelected, selectedIndex: 8, scrollOffset: 900, count: 17, viewportWidth: 880) == 850)
  }

  @Test func revealsAnAddedTabAtTheTrailingBoundary() {
    // Measured: 18 tabs, new tab at index 13 while scrolled to 300 → 910.
    #expect(TabStackLayout.revealOffset(forTabAt: 13, scrollOffset: 300, count: 18, viewportWidth: 880) == 910)
    #expect(TabStackLayout.revealOffset(forTabAt: 5, scrollOffset: 300, count: 18, viewportWidth: 880) == nil)
  }
}
