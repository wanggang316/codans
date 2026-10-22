import Testing

@testable import Codans

struct CommandQueuePageTests {
  @Test func collapsedShowsFirstThree() {
    let page = CommandQueuePage(entryCount: 10, availableHeight: 800, expanded: false, requestedPage: 2)
    #expect(page.range == 0..<3)
    #expect(page.index == 0)
  }

  @Test func expandedFitsAndPaginates() {
    let page = CommandQueuePage(entryCount: 10, availableHeight: 252, expanded: true, requestedPage: 1)
    #expect(page.range == 4..<8)
    #expect(page.count == 3)
  }

  @Test func drainingAndResizingClampPage() {
    let drained = CommandQueuePage(entryCount: 2, availableHeight: 252, expanded: true, requestedPage: 2)
    #expect(drained.index == 0)
    #expect(drained.range == 0..<2)
    let resized = CommandQueuePage(entryCount: 10, availableHeight: 800, expanded: true, requestedPage: 2)
    #expect(resized.range == 0..<10)
  }

  @Test func emptyAndSmallPanesHaveSafeRanges() {
    let empty = CommandQueuePage(entryCount: 0, availableHeight: 0, expanded: true, requestedPage: 5)
    #expect(empty.range.isEmpty)
    #expect(empty.index == 0)
    let small = CommandQueuePage(entryCount: 4, availableHeight: 120, expanded: false, requestedPage: 0)
    #expect(small.range == 0..<1)
  }
}
