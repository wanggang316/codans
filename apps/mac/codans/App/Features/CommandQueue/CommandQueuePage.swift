import Foundation

/// Keeps a non-scrolling queue inside the pane as commands drain or its size changes.
nonisolated struct CommandQueuePage {
  static let rowHeight: CGFloat = 44
  static let chromeHeight: CGFloat = 76

  let index: Int
  let count: Int
  let range: Range<Int>

  init(entryCount: Int, availableHeight: CGFloat, expanded: Bool, requestedPage: Int) {
    let capacity = max(1, Int(max(0, availableHeight - Self.chromeHeight) / Self.rowHeight))
    let pageSize = expanded ? capacity : min(3, capacity)
    count = max(1, (entryCount + pageSize - 1) / pageSize)
    index = expanded ? min(max(0, requestedPage), count - 1) : 0
    let start = index * pageSize
    range = start..<min(entryCount, start + pageSize)
  }
}
